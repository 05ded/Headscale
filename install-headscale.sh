#!/usr/bin/env bash
# Fresh VPS installer: Ubuntu 24.04 / Debian 12 or 13, root, systemd.
# Versions verified 2026-10-19. Never run over an existing installation.
set -Eeuo pipefail
umask 077
STACK=/opt/headscale-stack
BACKUPS=/opt/headscale-backups
HS_IMAGE=headscale/headscale:0.29.5
HP_IMAGE=ghcr.io/tale/headplane:0.8.1
log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'printf "\nInstallation stopped at line %s. Existing files were not deleted.\n" "$LINENO" >&2' ERR

if [[ ${1:-} == --help ]]; then
  cat <<'HELP'
Usage: sudo bash install-headscale.sh
Interactive installer for a NEW VPS. Creates /opt/headscale-stack.
Installs Docker if absent, Caddy HTTPS, Headscale, Headplane, DERP,
MagicDNS, restricted admin-to-server ACL, optional agent, daily backups.
Refuses an existing stack, Headscale containers or occupied ports.
Does not enable UFW, alter SSH rules, or delete an existing installation.
HELP
  exit 0
fi
[[ $EUID -eq 0 ]] || die 'Run as root: sudo bash install-headscale.sh'
[[ -r /etc/os-release ]] || die 'Linux with /etc/os-release is required.'
. /etc/os-release
case "$ID:${VERSION_ID}" in
  ubuntu:24.04|debian:12|debian:13) ;;
  *) die 'Supported: Ubuntu 24.04, Debian 12/13.' ;;
esac
command -v systemctl >/dev/null || die 'systemd is required.'
[[ ! -e $STACK && ! -L $STACK ]] || die "$STACK already exists. Refusing to overwrite it."
[[ ! -e /etc/headscale && ! -e /var/lib/headscale ]] || die 'Existing native Headscale configuration/data found. Use a NEW VPS.'
[[ ! -e /etc/systemd/system/headscale-stack-backup.service ]] || die 'Backup service already exists.'
if command -v docker >/dev/null; then
  docker info >/dev/null 2>&1 || die 'Docker exists but is not accessible. Start/fix Docker first.'
  if docker ps -a --format '{{.Names}} {{.Image}}' | grep -Eiq 'headscale|headplane|(^| )caddy( |:|$)'; then
    die 'Existing Headscale/Headplane/Caddy containers found. Use a NEW VPS.'
  fi
fi
if command -v ss >/dev/null; then
  [[ -z $(ss -H -ltn 'sport = :80 or sport = :443') ]] || die 'TCP 80/443 is occupied.'
  [[ -z $(ss -H -lun 'sport = :3478') ]] || die 'UDP 3478 is occupied.'
fi

log 'Enter settings. Public DNS A must point directly to this VPS (no CDN proxy).'
read -r -p 'Headscale domain (e.g. headscale.example.org): ' DOMAIN
read -r -p 'MagicDNS suffix (e.g. mesh.example.org): ' BASE_DOMAIN
read -r -p 'Public IPv4 of this VPS: ' PUBLIC_IPV4
read -r -p 'Enable Headplane Agent? [Y/n]: ' AGENT_ANSWER
DOMAIN=${DOMAIN,,}
BASE_DOMAIN=${BASE_DOMAIN,,}
valid_domain() {
  local value=$1 label
  [[ ${#value} -le 253 && $value == *.* && $value != *. && $value != .* && $value != *..* ]] || return 1
  local -a labels
  IFS=. read -r -a labels <<< "$value"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}
valid_domain "$DOMAIN" || die 'Invalid server domain (no https:// or path).'
valid_domain "$BASE_DOMAIN" || die 'Invalid MagicDNS suffix.'
[[ $DOMAIN != "$BASE_DOMAIN" && $DOMAIN != *."$BASE_DOMAIN" ]] || die 'MagicDNS must not overlap the server domain. Use sibling names: headscale.example.org and mesh.example.org.'
[[ $PUBLIC_IPV4 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'Invalid IPv4.'
IFS=. read -r -a octets <<< "$PUBLIC_IPV4"
for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || die 'Invalid IPv4 octet.'; done
ENABLE_AGENT=true
[[ ${AGENT_ANSWER,,} != n ]] || ENABLE_AGENT=false
printf '\nDomain: %s\nMagicDNS: %s\nIPv4: %s\nAgent: %s\n' "$DOMAIN" "$BASE_DOMAIN" "$PUBLIC_IPV4" "$ENABLE_AGENT"
printf 'Installs services and daily backup at 04:20 UTC. Headplane receives Docker socket access.\n'
read -r -p 'Type INSTALL to install on this NEW VPS: ' CONFIRM
[[ $CONFIRM == INSTALL ]] || die 'Cancelled; no installation changes made.'

log 'Installing prerequisites'
apt-get update
apt-get install -y ca-certificates curl openssl python3 iproute2
python3 - "$PUBLIC_IPV4" <<'PY'
import ipaddress, sys
ip = ipaddress.IPv4Address(sys.argv[1])
if not ip.is_global:
    raise SystemExit('Public, globally routable IPv4 required')
PY
python3 - "$DOMAIN" "$PUBLIC_IPV4" <<'PY'
import socket, sys
addresses = {entry[4][0] for entry in socket.getaddrinfo(sys.argv[1], 443, socket.AF_INET)}
if addresses != {sys.argv[2]}:
    raise SystemExit(f'DNS A must resolve only to {sys.argv[2]}; got {sorted(addresses)}. Fix DNS and rerun.')
PY

if ! command -v docker >/dev/null; then
  log 'Installing Docker from the official repository'
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 3 "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi
docker compose version >/dev/null || die 'Docker Compose plugin is missing.'

log 'Checking ports and downloading pinned application images'
[[ -z $(ss -H -ltn 'sport = :80 or sport = :443') ]] || die 'TCP 80/443 is occupied.'
[[ -z $(ss -H -lun 'sport = :3478') ]] || die 'UDP 3478 is occupied.'
docker pull "$HS_IMAGE"
docker pull "$HP_IMAGE"
docker pull caddy:2
CADDY_IMAGE=$(docker image inspect caddy:2 --format '{{index .RepoDigests 0}}')
[[ $CADDY_IMAGE == caddy@sha256:* ]] || die 'Cannot pin Caddy digest.'

install -d -m 700 "$STACK" "$BACKUPS"
cd "$STACK"
mkdir -p headscale/config headscale/data headplane/data caddy/data caddy/config
COOKIE_SECRET=$(openssl rand -hex 16)
cat > headscale/config/config.yaml <<EOF
server_url: https://$DOMAIN
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
    write_ahead_log: true
node:
  expiry: 0
  ephemeral:
    inactivity_timeout: 30m
policy:
  mode: database
dns:
  magic_dns: true
  base_domain: $BASE_DOMAIN
  override_local_dns: false
  nameservers:
    global: []
    split: {}
  search_domains: []
  extra_records: []
derp:
  server:
    enabled: true
    region_id: 999
    region_code: ded
    region_name: My VPS DERP
    verify_clients: true
    stun_listen_addr: 0.0.0.0:3478
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
    ipv4: $PUBLIC_IPV4
    ipv6: ""
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  paths: []
  auto_update_enabled: true
  update_frequency: 3h
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
log:
  format: text
  level: info
logtail:
  enabled: false
EOF
cat > headplane/config.yaml <<EOF
server:
  host: "0.0.0.0"
  port: 3000
  base_url: "https://$DOMAIN"
  cookie_secret: "$COOKIE_SECRET"
  cookie_secure: true
  data_path: "/var/lib/headplane"
headscale:
  url: "http://headscale:8080"
  public_url: "https://$DOMAIN"
  config_path: "/etc/headscale/config.yaml"
integration:
  agent:
    enabled: false
    cache_ttl: 180000
    work_dir: "/var/lib/headplane/agent"
  docker:
    enabled: true
    container_label: "me.tale.headplane.target=headscale"
    socket: "unix:///var/run/docker.sock"
EOF
cat > caddy/Caddyfile <<EOF
$DOMAIN {
    @headplane path /admin /admin/*
    handle @headplane {
        reverse_proxy headplane:3000
    }
    handle {
        reverse_proxy headscale:8080
    }
}
EOF
cat > compose.yaml <<EOF
name: headscale-stack
x-logging: &logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
services:
  caddy:
    image: $CADDY_IMAGE
    restart: unless-stopped
    ports:
      - "80:80/tcp"
      - "443:443/tcp"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/data:/data
      - ./caddy/config:/config
    logging: *logging
  headscale:
    image: $HS_IMAGE
    restart: unless-stopped
    command: serve
    labels:
      me.tale.headplane.target: headscale
    ports:
      - "3478:3478/udp"
    volumes:
      - ./headscale/config:/etc/headscale
      - ./headscale/data:/var/lib/headscale
    tmpfs:
      - /var/run/headscale
    logging: *logging
  headplane:
    image: $HP_IMAGE
    restart: unless-stopped
    depends_on:
      - headscale
    volumes:
      - ./headplane/config.yaml:/etc/headplane/config.yaml:ro
      - ./headplane/data:/var/lib/headplane
      - ./headscale/config:/etc/headscale
      - /var/run/docker.sock:/var/run/docker.sock:ro
    logging: *logging
EOF

# Restrict new connections before enrolling any client.
cat > headscale/config/policy-initial.hujson <<'EOF'
{
  "groups": {
    "group:admins": ["admin@"],
    "group:servers": ["servers@"]
  },
  "acls": [
    {"action":"accept","proto":"icmp","src":["group:admins"],"dst":["group:servers:*"]},
    {"action":"accept","proto":"58","src":["group:admins"],"dst":["group:servers:*"]},
    {"action":"accept","src":["group:admins"],"dst":["group:servers:3389"]}
  ],
  "ssh": []
}
EOF

log 'Starting Headscale and creating users / ACL'
docker compose config --quiet
docker compose up -d headscale
ready=false
for ((attempt=1; attempt<=30; attempt++)); do
  if docker compose exec -T headscale headscale users list >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
if [[ $ready != true ]]; then
  docker compose logs --tail 50 headscale
  die 'Headscale did not start. Inspect logs; do not delete the data directory.'
fi
docker compose exec -T headscale headscale users create admin
docker compose exec -T headscale headscale users create servers
docker compose exec -T headscale headscale policy check --file /etc/headscale/policy-initial.hujson
docker compose exec -T headscale headscale policy set --file /etc/headscale/policy-initial.hujson

# Keys stay in root-readable files; never print them or put them in arguments.
ADMIN_KEY=$(docker compose exec -T headscale headscale apikeys create --expiration 365d | tr -d '\r' | grep -E '^hskey-api-[A-Za-z0-9_-]+$')
[[ -n $ADMIN_KEY ]] || die 'Cannot read the generated admin API key.'
printf '%s\n' "$ADMIN_KEY" > admin-api-key.txt
if [[ $ENABLE_AGENT == true ]]; then
  AGENT_KEY=$(docker compose exec -T headscale headscale apikeys create --expiration 365d | tr -d '\r' | grep -E '^hskey-api-[A-Za-z0-9_-]+$')
  [[ -n $AGENT_KEY ]] || die 'Cannot read the generated agent API key.'
  printf '%s\n' "$AGENT_KEY" > headplane/agent-api-key.txt
  python3 - <<'PY'
from pathlib import Path
path = Path('headplane/config.yaml')
key = Path('headplane/agent-api-key.txt').read_text().strip()
text = path.read_text().replace('integration:\n', f'  api_key: "{key}"\nintegration:\n', 1)
text = text.replace('  agent:\n    enabled: false', '  agent:\n    enabled: true', 1)
path.write_text(text)
PY
fi

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  log 'Adding web/STUN rules to already enabled UFW (SSH rules unchanged)'
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 3478/udp
fi
log 'Starting Caddy and Headplane'
docker compose up -d

log 'Installing backup command and daily timer'
cat > "$STACK/backup.sh" <<'BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
cd /opt/headscale-stack
exec 9>/run/lock/headscale-stack-backup.lock
flock -n 9 || { echo 'Backup already running'; exit 1; }
mkdir -p /opt/headscale-backups
archive="/opt/headscale-backups/stack-$(date -u +%Y%m%d-%H%M%S).tar.gz"
restart_services() { docker compose start headscale headplane; }
trap restart_services EXIT
docker compose stop headplane headscale
tar -czf "$archive.partial" compose.yaml headscale headplane caddy admin-api-key.txt backup.sh
gzip -t "$archive.partial"
mv -- "$archive.partial" "$archive"
chmod 600 "$archive"
printf 'Backup saved: %s\n' "$archive"
# No automatic deletion: copy backups off-server and monitor disk usage.
BACKUP
chmod 700 "$STACK/backup.sh"
cat > /etc/systemd/system/headscale-stack-backup.service <<'EOF'
[Unit]
Description=Consistent Headscale stack backup (briefly stops Headscale and its DERP)
Requires=docker.service
After=docker.service
[Service]
Type=oneshot
ExecStart=/opt/headscale-stack/backup.sh
TimeoutStartSec=15min
EOF
cat > /etc/systemd/system/headscale-stack-backup.timer <<'EOF'
[Unit]
Description=Daily Headscale backup at 04:20 UTC
[Timer]
OnCalendar=*-*-* 04:20:00 UTC
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now headscale-stack-backup.timer

cat > NEXT-STEPS.txt <<EOF
Panel: https://$DOMAIN/admin
Admin API key: /opt/headscale-stack/admin-api-key.txt (root only; expires in 365 days).
Agent API key also expires in 365 days; replace it before expiry.
Users: admin (administrator computers), servers (RDP targets).
Show numeric user IDs:
  cd /opt/headscale-stack
  docker compose exec headscale headscale users list
Create a one-time enrollment key (replace USER_ID):
  docker compose exec headscale headscale preauthkeys create --user USER_ID --expiration 1h
On the client:
  tailscale up --login-server=https://$DOMAIN --auth-key=KEY
  tailscale set --accept-dns=true
Check your DERP:
  tailscale debug derp ded
DNS name format: device.$BASE_DOMAIN
Clients: Tailscale 1.80.0 or newer.
ACL: admin -> servers ICMPv4/ICMPv6 and RDP TCP/UDP 3389 only.
Agent may collect limited information under restrictive ACL; inspect logs before changing ACL.
Public firewall / provider security group: TCP 80, TCP 443, UDP 3478; keep SSH accessible.
Backup manually: sudo /opt/headscale-stack/backup.sh
Daily backup: 04:20 UTC / 07:20 Moscow; briefly stops Headscale and embedded DERP.
Backups: /opt/headscale-backups. Copy off-server; monitor space (no automatic pruning).
Restore ONLY with matching image versions and a complete backup; do not downgrade a migrated database.
Logs: docker compose logs --since 5m --tail 80 headscale headplane caddy
This is a fresh-install script, not an updater. Never delete the data folder to rerun it.
EOF

log 'Checking public HTTPS (up to two minutes for certificate issuance)'
HTTPS_OK=false
for ((attempt=1; attempt<=24; attempt++)); do
  if curl --connect-timeout 3 --max-time 5 -fsS "https://$DOMAIN/health" >/dev/null; then HTTPS_OK=true; break; fi
  sleep 5
done
docker compose ps
if [[ $HTTPS_OK == true ]]; then
  log "HTTPS OK. Open https://$DOMAIN/admin"
else
  printf '\nHTTPS not confirmed. Check DNS, provider firewall TCP 80/443, and Caddy logs.\n' >&2
fi
printf '\nAdmin key (read locally on VPS): sudo cat %s/admin-api-key.txt\n' "$STACK"
printf 'Instructions: %s/NEXT-STEPS.txt\n' "$STACK"
printf 'No client was enrolled automatically. Check panel, DERP and RDP from a real client.\n'
