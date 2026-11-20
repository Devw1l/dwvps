# Установка и первичная настройка — проект runbook

## Единый установщик controller и node

`vpn-control.sh` запускается на Mac из папки проекта. Серверы должны иметь чистую Ubuntu 24.04 x86-64 и SSH-вход под `root` на `22/tcp`. Перед первым запуском проверь отпечаток каждого сервера через консоль провайдера и установи обычное SSH-соединение. Оставь консоль и исходную SSH-сессию доступными до завершения.

```bash
bash operations/vpn-control.sh plan controller
bash operations/vpn-control.sh preflight controller IP_RU
bash operations/vpn-control.sh install controller IP_RU
bash operations/vpn-control.sh install node IP_VPS1
```

Если все четыре VPS готовы, запускай `bash operations/vpn-control.sh install-all IP_RU IP_VPS1 IP_VPS2 IP_VPS3`. Можно указать путь к общему ключу `root` последним аргументом. Если ключи `root` различаются, выполняй `install` по одному серверу с соответствующим ключом. Пакетный режим останавливается на первой ошибке. Повторный запуск проверяет завершённые серверы и сохраняет их конфигурацию. Вход под `root` или пароль `sudo` для `ops` может потребовать ввода в терминале.

Установщик обновляет систему, создаёт `ops`, проверяет SSH-ключ и `sudo`. На `controller` ставит локальный PostgreSQL для будущего VPN Control. На `node` проверяет запуск поставляемого Xray. В обеих ролях устанавливает [3X-UI v3.11.0](https://github.com/MHSanaei/3x-ui/releases/tag/v3.11.0) из проверенного по SHA-256 архива, создаёт администратора панели и проверяет вход в неё. Затем включает UFW, ограничивает SSH и проверяет новое независимое соединение. При сбое итоговой проверки сервер восстанавливает вход через SSH и выключает UFW через три минуты.

```bash
bash operations/vpn-control.sh status IP_СЕРВЕРА
bash operations/vpn-control.sh credentials IP_СЕРВЕРА
bash operations/vpn-control.sh tunnel IP_СЕРВЕРА
```

`status` проверяет роль, службу, локальный порт панели и PostgreSQL на контроллере. `credentials` выводит данные одной панели через `sudo`. `tunnel` открывает `127.0.0.1:12053` на Mac для URL из `credentials`. Перед открытием туннеля к другому серверу останови предыдущий. После первого входа включи TOTP и сохрани пароль в менеджере паролей.

Панели слушают только loopback и используют собственные SQLite. Этот этап подготавливает четыре сервера по ролям. Приватный канал между контроллером и узлами, регистрация нод, выдача VPN-профилей, Telegram-бот и внешние резервные копии относятся к следующим этапам. Клиентские порты пока не открываются.

## Полное развёртывание VPN Control

1. Inventory (no secrets): OS, versions, vCPU/RAM, net interfaces, host firewalls, IPv4/v6, domains, certificates, current 3X-UI nodes, existing ports, back-ups.
2. `vpn-control doctor`: non-destructive preflight OS/support matrix, routing, DNS, port collision, API, systemd, storage, required binaries.
3. Backup of existing 3X-UI and credentials with encrypted offsite copy and restore dry-run.
4. `vpn-control install --role controller --dry-run`: projected changes and rollback actions.
5. Explicit admin approval, provision RU control plane (private services, DB, SSL, bot isolated network namespace) with no hidden public API.
6. Add three VPS through `vpn-control node add` with signed provisioning records and permissions.
7. Deploy protocol profiles one by one, verify UDP/TCP and client import.
8. Configure dual Telegram tunnels and test no direct escape; verify independent SSH recovery.
9. Execute full acceptance suite and signed release report.

Actual shell commands and package versions must be generated only after step 1; copying a generic script to uninspected live servers is not permitted. Do not `curl | bash` without source pin/checksum/signature verification.
