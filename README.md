# Headscale + Headplane в Docker

Полная настройка сети на новом VPS: **Headscale, Headplane, HTTPS через Caddy, MagicDNS, свой DERP, агент и резервные копии**.

> Выберите автоматическую или ручную установку. На действующем сервере не запускайте установщик и не заменяйте конфиги: инструкция рассчитана на новую установку.

Версии сверены 19 октября 2026 года: **Headscale 0.29.5**, **Headplane 0.8.1**. Caddy устанавливается из ветки 2 и затем закрепляется по digest. Скрипт проверен на синтаксис Bash, JSON ACL и подстановки шаблонов. Полный запуск контейнеров на новом VPS ещё не проверен.

## Содержание

- [Требования](#требования)
- [Автоматическая установка](#автоматическая-установка)
- [Ручная установка](#ручная-установка)
- [Подключение клиентов](#подключение-клиентов)
- [Headplane Agent](#headplane-agent)
- [MagicDNS и DERP](#magicdns-и-derp)
- [Резервные копии](#резервные-копии)
- [Обновление и диагностика](#обновление-и-диагностика)

## Требования

- Новый VPS с Ubuntu 24.04 или Debian 12/13, systemd, root и публичным IPv4.
- Рекомендуется от 1 ГБ RAM и запас диска для контейнеров и архивов; нагрузка DERP зависит от трафика.
- Совместимая с образами архитектура VPS, обычно amd64 или arm64.
- Клиенты Tailscale версии **1.80.0 или новее**.
- Свободные TCP 80/443 и UDP 3478.

Замените значения во всех примерах:

| Пример | Что указать |
|---|---|
| `headscale.example.org` | Публичный домен сервера |
| `mesh.example.org` | Отдельный суффикс MagicDNS |
| `PUBLIC_IPV4` | Публичный IPv4 VPS |
| `COOKIE_SECRET` | Секрет ровно из 32 символов |

Создайте DNS-запись `headscale.example.org → A → PUBLIC_IPV4`. При Cloudflare используйте DNS only. AAAA добавляйте только при наличии работающего публичного IPv6. Для `mesh.example.org` публичная запись не требуется.

MagicDNS не должен использовать домен сервера или его родительскую зону: используйте соседние имена `headscale.example.org` и `mesh.example.org`.

В сетевом экране провайдера разрешите TCP 80, TCP 443 и UDP 3478. Сохраните доступ по своему SSH-порту. Порты 3000, 8080, 9090 и 50443 не публикуются. Docker может обрабатывать опубликованные порты отдельно от обычных правил UFW.

Headscale координирует сеть. Трафик клиентов идёт напрямую либо через DERP; Headplane предоставляет панель управления.

## Автоматическая установка

Скачайте файл из своего репозитория, заменив `OWNER`, `REPOSITORY` и при необходимости имя ветки `main`:

```bash
curl -fL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/install-headscale.sh \
  -o install-headscale.sh
less install-headscale.sh
sudo bash install-headscale.sh
```

Для приватного репозитория передайте файл через SCP/WinSCP или используйте авторизованное скачивание. Публичная raw-ссылка без доступа не сработает.

Введите домен, MagicDNS-суффикс, IPv4 VPS и необходимость агента. Подтвердите словом `INSTALL`.

Скрипт проверяет DNS и порты, отказывается перезаписывать существующий проект или обнаруженную установку, устанавливает Docker при его отсутствии и создаёт сервисы. SSH не меняет; UFW не включает. Если UFW уже активен, добавляет правила web/STUN.

Результат:

| Путь | Назначение |
|---|---|
| `/opt/headscale-stack` | Проект |
| `/opt/headscale-stack/admin-api-key.txt` | Ключ входа, только root |
| `/opt/headscale-stack/NEXT-STEPS.txt` | Подключение клиентов и проверки |
| `/opt/headscale-backups` | Архивы |

```bash
cd /opt/headscale-stack
docker compose ps
sudo cat admin-api-key.txt
cat NEXT-STEPS.txt
```

Откройте `https://headscale.example.org/admin`, войдите ключом. Переходите к подключению клиентов; ручную установку пропустите.

API-ключи действуют 365 дней: замените до истечения. Скрипт не предназначен для обновлений. При ошибке не удаляйте папку данных ради повторного запуска.

## Ручная установка

Команды выполняются от root на новом VPS: при необходимости сначала `sudo -i`.

### 1. Docker

Если Docker и Compose уже установлены и работают, пропустите шаг. Команды рассчитаны на чистую Ubuntu/Debian без конфликтующих пакетов Docker.

```bash
apt-get update
apt-get install -y ca-certificates curl openssl python3 nano
install -m 0755 -d /etc/apt/keyrings
. /etc/os-release
curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
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
docker version
docker compose version
```

### 2. Папки

Не продолжайте, если `/opt/headscale-stack` уже существует.

```bash
umask 077
mkdir /opt/headscale-stack
cd /opt/headscale-stack
mkdir -p headscale/config headscale/data headplane/data caddy/data caddy/config
```

### 3. Конфигурации

Создавайте файлы через `nano ПУТЬ`. Все пути ниже относятся к `/opt/headscale-stack`. Замените примеры доменов и IP до запуска.

**`headscale/config/config.yaml`:**

```yaml
server_url: https://headscale.example.org
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
  base_domain: mesh.example.org
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
    ipv4: PUBLIC_IPV4
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
```

`node.expiry: 0` отключает автоматическое истечение ключей новых устройств: удаляйте потерянные или выведенные из эксплуатации узлы. `override_local_dns: false` сохраняет обычные локальные DNS, MagicDNS обслуживает имена сети. Публичные DERP оставлены резервными.

**`caddy/Caddyfile`:**

```caddyfile
headscale.example.org {
    @headplane path /admin /admin/*
    handle @headplane {
        reverse_proxy headplane:3000
    }
    handle {
        reverse_proxy headscale:8080
    }
}
```

**`headplane/config.yaml`:**

Сначала создайте секрет: `openssl rand -hex 16`. Полученные 32 символа вставьте вместо `COOKIE_SECRET`. Агент пока отключён.

```yaml
server:
  host: "0.0.0.0"
  port: 3000
  base_url: "https://headscale.example.org"
  cookie_secret: "COOKIE_SECRET"
  cookie_secure: true
  data_path: "/var/lib/headplane"
headscale:
  url: "http://headscale:8080"
  public_url: "https://headscale.example.org"
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
```

**`compose.yaml`:**

```yaml
name: headscale-stack
x-logging: &logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
services:
  caddy:
    image: caddy:2
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
    image: headscale/headscale:0.29.5
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
    image: ghcr.io/tale/headplane:0.8.1
    restart: unless-stopped
    depends_on:
      - headscale
    volumes:
      - ./headplane/config.yaml:/etc/headplane/config.yaml:ro
      - ./headplane/data:/var/lib/headplane
      - ./headscale/config:/etc/headscale
      - /var/run/docker.sock:/var/run/docker.sock:ro
    logging: *logging
```

Сеть Compose создаётся автоматически. Сервисы обращаются друг к другу по именам. Headplane получает Docker socket для управления Headscale: это широкие права даже с `:ro`. Доступ к панели должен быть только у администраторов.

Если UFW уже включён:

```bash
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3478/udp
```

Не включайте UFW, пока не разрешили свой SSH-порт. Правила провайдера настройте отдельно.

### 4. Запуск Headscale

```bash
docker compose config --quiet
docker compose pull
docker compose up -d headscale
docker compose logs --tail 30 headscale
docker compose exec headscale headscale users list
```

Если последняя команда выполнена до готовности сервера, повторите через несколько секунд. При постоянной ошибке сначала исправьте причину в логах.

### 5. Пользователи и ACL

```bash
docker compose exec headscale headscale users create admin
docker compose exec headscale headscale users create servers
docker compose exec headscale headscale users list
```

Создайте `headscale/config/policy-initial.hujson`:

```json
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
```

Проверьте правила:

```bash
docker compose exec headscale headscale policy check --file /etc/headscale/policy-initial.hujson
```

Только после `Policy is valid`:

```bash
docker compose exec headscale headscale policy set --file /etc/headscale/policy-initial.hujson
```

Примените ACL до регистрации клиентов. Администраторы получают пинг IPv4/IPv6 и RDP TCP/UDP 3389 к устройствам пользователя `servers`. Остальные новые соединения запрещены. Для SSH, доступа между серверами и других служб нужны отдельные правила.

`admin@` в ACL — ссылка на пользователя `admin`; переименовывать пользователя не нужно. Действующая политика хранится в базе, файл выше — исходный пример. Перед последующими изменениями выгружайте актуальные правила:

```bash
docker compose exec -T headscale headscale policy get > policy-current.hujson
```

### 6. Панель и HTTPS

```bash
docker compose up -d
docker compose ps
docker compose logs --tail 30 caddy
docker compose logs --tail 30 headplane
curl -fsS https://headscale.example.org/health
docker compose exec headscale headscale apikeys create --expiration 365d
```

Откройте `https://headscale.example.org/admin`, введите ключ. Сохраните его в менеджере паролей и замените до истечения 365 дней.

После успешной проверки закрепите Caddy:

```bash
docker image inspect caddy:2 --format '{{index .RepoDigests 0}}'
```

Полученную строку `caddy@sha256:...` укажите вместо `caddy:2` в Compose. Автоустановщик делает это самостоятельно.

## Подключение клиентов

Установите актуальный [Tailscale](https://tailscale.com/download) на Windows/Linux/macOS. Минимум для этой версии Headscale — 1.80.0.

На VPS узнайте числовой ID пользователя:

```bash
cd /opt/headscale-stack
docker compose exec headscale headscale users list
docker compose exec headscale headscale preauthkeys create --user USER_ID --expiration 1h
```

Замените `USER_ID` числовым ID: `admin` для административного компьютера, `servers` для сервера. Ключ показывается один раз и без `--reusable` является одноразовым.

На клиенте в терминале или PowerShell с нужными правами:

```bash
tailscale up --login-server=https://headscale.example.org --auth-key=KEY
tailscale set --accept-dns=true
tailscale status
```

Замените `KEY` полученным ключом. На VPS проверьте:

```bash
docker compose exec headscale headscale nodes list
```

RDP должен быть отдельно включён на целевой Windows и разрешён её брандмауэром. ACL Headscale не включает службы операционной системы.

## Headplane Agent

Если включили агент в установщике, этот раздел повторять не нужно. Для ручной установки создайте отдельный API-ключ:

```bash
docker compose exec headscale headscale apikeys create --expiration 365d
```

В `headplane/config.yaml`, внутри существующего `headscale:`, добавьте:

```yaml
  api_key: "API_КЛЮЧ_АГЕНТА"
```

В существующем `integration.agent` установите:

```yaml
  agent:
    enabled: true
    cache_ttl: 180000
    work_dir: "/var/lib/headplane/agent"
```

Сохраните `integration.docker`. Не создавайте повторные блоки YAML.

```bash
docker compose restart headplane
docker compose logs --since 2m --tail 60 headplane
```

Ищите `Sync complete`. Синхронизация выполняется примерно раз в три минуты. Сведения зависят от состояния узлов и ACL: успешный запуск не гарантирует получение данных обо всех устройствах. При неполных данных изучите логи, не разрешайте без необходимости доступ «всем всё».

Ключ агента истекает через 365 дней. Отдельный контейнер или ручной pre-auth key для этой версии не нужен.

## MagicDNS и DERP

На клиенте проверьте MagicDNS, подставив реальное имя узла:

```powershell
tailscale set --accept-dns=true
ping server-name.mesh.example.org
```

В первой строке должен появиться соответствующий IP `100.64.x.x`. Даже без ответов на ICMP правильное разрешение имени уже подтверждает работу DNS. Имя пользователя `servers` не равно имени устройства.

Проверка DERP:

```powershell
tailscale debug derp ded
tailscale netcheck
```

Нужны успешное DERP-соединение и IPv4 STUN-ответ. Если IPv6 нет, ошибка отдельной проверки IPv6 сама по себе не означает отказ IPv4 DERP. Не указывайте примерный `2001:db8::1`.

Чтобы использовать исключительно свой DERP, после проверки замените `derp.urls` на `[]` и перезапустите Headscale. При отказе своего VPS публичного резервного ретранслятора тогда не будет.

Проверка пути к другому устройству:

```powershell
tailscale ping --c 20 100.64.0.3
tailscale status
```

`direct` / `via IP:порт` — напрямую. `DERP(ded)` — через VPS. Удаление DERP не заставляет соединения стать прямыми: путь зависит от NAT, UDP и брандмауэров на сторонах клиентов.

## Резервные копии

Архив содержит базу, приватные ключи и конфиги Headscale, данные Headplane, сертификаты Caddy и Compose. Храните его защищённо и копируйте вне VPS.

### Автоматическая установка

```bash
sudo /opt/headscale-stack/backup.sh
systemctl list-timers headscale-stack-backup.timer
journalctl -u headscale-stack-backup.service --no-pager -n 30
```

Архивы создаются в 04:20 UTC / 07:20 МСК. На время согласованной копии SQLite ненадолго останавливаются Headplane, Headscale и его DERP. Архивы автоматически не удаляются: следите за диском.

### Ручная установка

Создайте `/opt/headscale-stack/backup.sh`:

```bash
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
tar -czf "$archive.partial" compose.yaml headscale headplane caddy backup.sh
gzip -t "$archive.partial"
mv -- "$archive.partial" "$archive"
chmod 600 "$archive"
printf 'Backup saved: %s\n' "$archive"
# No automatic deletion: copy backups off-server and monitor disk usage.
```

```bash
chmod 700 /opt/headscale-stack/backup.sh
mkdir -p /opt/headscale-backups
chmod 700 /opt/headscale-backups
/opt/headscale-stack/backup.sh
```

Создайте `/etc/systemd/system/headscale-stack-backup.service`:

```ini
[Unit]
Description=Consistent Headscale stack backup (briefly stops Headscale and its DERP)
Requires=docker.service
After=docker.service
[Service]
Type=oneshot
ExecStart=/opt/headscale-stack/backup.sh
TimeoutStartSec=15min
```

Создайте `/etc/systemd/system/headscale-stack-backup.timer`:

```ini
[Unit]
Description=Daily Headscale backup at 04:20 UTC
[Timer]
OnCalendar=*-*-* 04:20:00 UTC
Persistent=true
[Install]
WantedBy=timers.target
```

```bash
systemctl daemon-reload
systemctl enable --now headscale-stack-backup.timer
systemctl list-timers headscale-stack-backup.timer
```

Периодически проверяйте восстановление в отдельной среде. Наличие архива само по себе не подтверждает его пригодность.

## Обновление и диагностика

Перед обновлением создайте копию, прочитайте release notes Headscale/Headplane и требования к клиентам. Обновляйте Headscale по соседним веткам без пропусков, например `0.29 → 0.30 → 0.31`. После каждого этапа проверяйте запуск, ACL, DNS и клиентов.

```bash
cd /opt/headscale-stack
./backup.sh
# Измените image в compose.yaml после изучения изменений
docker compose pull headscale
docker compose up -d --no-deps headscale
docker compose logs --since 2m --tail 50 headscale
```

Для нового образа Headplane также нужен `up -d --no-deps headplane`: простой `restart` образ не обновляет.

Для отката не запускайте старый Headscale поверх мигрированной базы. Восстанавливайте полный согласованный архив с соответствующими версиями образов, предварительно сохранив текущее состояние. Проверяйте архив на отдельном VPS; не подключайте две копии с одинаковыми ключами одновременно к рабочей сети. При переносе на другой IP исправьте DNS A и `derp.server.ipv4`.

Основные команды:

```bash
docker compose ps
docker compose logs --since 5m --tail 80 headscale
docker compose logs --since 5m --tail 80 headplane
docker compose logs --since 5m --tail 80 caddy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
# После успешной проверки Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

| Ошибка | Что проверить |
|---|---|
| Headscale Unreachable | Сначала статус и логи Headscale, затем ключ и URL Headplane |
| Конфликт server_url / base_domain | Отдельная зона MagicDNS, например mesh.example.org |
| Username has to contain @ | Ссылки пользователей в ACL: admin@ |
| Нет HTTPS | DNS, TCP 80/443, отсутствие CDN-прокси, конфликт портов |
| DERP не отвечает STUN | UDP 3478 в Compose, на VPS и у провайдера |
| Нет данных агента | Ключ, логи, состояние устройств и ACL |
| Нет RDP | ACL, служба RDP, поддержка в редакции Windows и Windows Firewall |
| Не разрешаются имена | accept-dns, имя узла и DNS-суффикс |
| Restart loop | Первая ошибка запуска; не удаляйте базу |

Не публикуйте рабочие конфиги, API-ключи, папки данных и резервные копии в GitHub. В репозитории оставьте установщик, документацию и шаблоны без секретов.

## Источники

- [Docker: Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker: Debian](https://docs.docker.com/engine/install/debian/)
- [Headscale в контейнере](https://headscale.net/stable/setup/install/container/)
- [Конфигурация Headscale 0.29.5](https://github.com/juanfont/headscale/blob/v0.29.5/config-example.yaml)
- [Обновление Headscale](https://headscale.net/stable/setup/upgrade/)
- [DNS](https://headscale.net/stable/ref/dns/)
- [DERP](https://headscale.net/stable/ref/derp/)
- [Конфигурация Headplane 0.8.1](https://github.com/tale/headplane/blob/v0.8.1/config.example.yaml)
- [Headplane Agent](https://headplane.net/features/agent)
