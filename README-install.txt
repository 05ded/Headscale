Установка Headscale с нуля — 19.10.2026

Для НОВОГО VPS: Ubuntu 24.04 или Debian 12/13, systemd, root.
Не запускайте поверх своей существующей установки.

1. Создайте A-запись домена на публичный IPv4 VPS, без CDN-прокси.
2. Разрешите в панели провайдера TCP 80/443 и UDP 3478, сохраните SSH.
3. Передайте install-headscale.sh на VPS, например через WinSCP в /root.
4. Запустите на VPS:
   sudo bash /root/install-headscale.sh
5. Введите домен Headscale, отдельный MagicDNS-суффикс, IPv4 VPS.
   Например: headscale.example.org и mesh.example.org.
6. Подтвердите словом INSTALL.

Скрипт создаёт:
- Docker (при отсутствии) из официального репозитория;
- Headscale 0.29.5, Headplane 0.8.1, Caddy с закреплённым digest;
- HTTPS, MagicDNS, встроенный DERP ded и публичные резервные DERP;
- необязательный Headplane Agent с отдельным API-ключом;
- пользователей admin и servers;
- ACL: admin -> servers, пинг IPv4/IPv6 и RDP TCP/UDP 3389;
- ежедневный архив в 04:20 UTC (07:20 МСК).

Папка проекта: /opt/headscale-stack
Панель: https://ВАШ_ДОМЕН/admin
Ключ входа: /opt/headscale-stack/admin-api-key.txt (доступ только root).
Срок API-ключей — 365 дней: замените до истечения.
Инструкции подключения: /opt/headscale-stack/NEXT-STEPS.txt
Архивы: /opt/headscale-backups
Ручная копия: sudo /opt/headscale-stack/backup.sh

Резервирование ненадолго останавливает Headscale и встроенный DERP.
Архивы не удаляются автоматически: следите за диском и копируйте вне VPS.
Headplane получает широкий доступ к Docker socket для управления Headscale.
Агент при строгих ACL может собирать неполные сведения — проверяйте его логи.
Скрипт не меняет SSH, не включает UFW и не удаляет существующие установки.
Если UFW уже включён, добавляет TCP 80/443 и UDP 3478.
Если установка прервана, изучите ошибку и файлы; не удаляйте данные ради перезапуска.

Источники:
https://docs.docker.com/engine/install/ubuntu/
https://headscale.net/stable/setup/install/container/
https://github.com/juanfont/headscale/blob/v0.29.5/config-example.yaml
https://github.com/tale/headplane/blob/v0.8.1/config.example.yaml
https://headplane.net/features/agent
https://headscale.net/stable/ref/derp/

Проверка в среде автора: синтаксис Bash, JSON ACL и подстановки шаблонов.
Полный запуск контейнеров и проверку сертификата нужно выполнить на новом Linux VPS.
