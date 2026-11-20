#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Установщик VPN Control для чистой Ubuntu 24.04 x86_64. Запуск с Mac.

  bash $0 plan controller|node
  bash $0 preflight controller|node IP_ИЛИ_DNS [КЛЮЧ_ROOT]
  bash $0 install controller|node IP_ИЛИ_DNS [КЛЮЧ_ROOT]
  bash $0 install-all RU VPS1 VPS2 VPS3 [ОБЩИЙ_КЛЮЧ_ROOT]
  bash $0 status IP_ИЛИ_DNS
  bash $0 credentials IP_ИЛИ_DNS
  bash $0 tunnel IP_ИЛИ_DNS
EOF
}

bad_args() { usage >&2; exit 2; }
valid_host() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; }
valid_role() { [[ $1 == controller || $1 == node ]]; }

action=${1:---help}
case "$action" in
  --help|-h) usage; exit 0 ;;
  plan)
    [[ $# == 2 ]] && valid_role "$2" || bad_args
    printf 'Роль: %s. План не выполняет SSH и не изменяет сервер.\n' "$2"
    printf '%s\n' '1. Проверить Ubuntu 24.04 x86_64, корневой доступ, порт 22 и текущий UFW.'
    if [[ $2 == controller ]]; then
      echo '   Обновить систему, установить и проверить локальный PostgreSQL.'
    else
      echo '   Обновить систему. Подготовить ноду с Xray без локального PostgreSQL.'
    fi
    printf '%s\n' '2. Создать ops и проверить вход по ключу и sudo.' \
      '3. Установить закреплённую 3X-UI, проверить пароль и доступ на loopback.' \
      '4. Включить UFW и ограничить SSH, оставив таймер отката.' \
      '5. Проверить новое SSH-соединение и записать результат установки.'
    exit 0 ;;
  install-all)
    [[ $# == 5 || $# == 6 ]] || bad_args
    for target in "$2" "$3" "$4" "$5"; do valid_host "$target" || bad_args; done
    unique=$(printf '%s\n' "$2" "$3" "$4" "$5" | LC_ALL=C sort -fu | wc -l)
    [[ $unique -eq 4 ]] || { echo 'Нужно указать четыре разных сервера.' >&2; exit 2; }
    controller=$2
    nodes=("$3" "$4" "$5")
    shift 5
    bash "$0" install controller "$controller" "$@"
    for target in "${nodes[@]}"; do bash "$0" install node "$target" "$@"; done
    echo 'Проверка установки завершилась на всех четырёх серверах.'
    exit 0 ;;
  install|preflight)
    [[ $# == 3 || $# == 4 ]] || bad_args
    valid_role "$2" && valid_host "$3" || bad_args
    role=$2
    host=$3
    shift 3 ;;
  status|credentials|tunnel)
    [[ $# == 2 ]] && valid_host "$2" || bad_args
    host=$2
    shift 2 ;;
  *) bad_args ;;
esac

ops_key="$HOME/.ssh/ru-vps-ops"
ssh_options=(-o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=10
             -o ServerAliveCountMax=3 -a -x -p 22)
ops_ssh() {
  ssh "${ssh_options[@]}" -S none -o ControlMaster=no -o BatchMode=yes \
    -o ClearAllForwardings=yes -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -i "$ops_key" "$@"
}
load_ops_key() {
  local fingerprint
  fingerprint=$(ssh-keygen -lf "$ops_key.pub" | awk '{print $2}')
  [[ -n $fingerprint ]] || return 1
  if ! ssh-add -l | grep -Fq "$fingerprint"; then ssh-add -t 900 "$ops_key"; fi
}
show_status() {
  ops_ssh "ops@$host" 'bash -se' <<'REMOTE'
role=$(cat /etc/vpn-control-role)
printf 'Роль: %s\n' "$role"
systemctl is-active x-ui.service
systemctl is-enabled x-ui.service
sockets=$(ss -H -ltn '( sport = :2053 )' | awk '{print $4}')
test "$sockets" = '127.0.0.1:2053'
printf 'Панель: %s\n' "$sockets"
if [[ $role == controller ]]; then pg_isready; fi
REMOTE
}
if [[ $action != install && $action != preflight ]]; then
  [[ -r $ops_key ]] || { echo "SSH-ключ не найден: $ops_key" >&2; exit 1; }
  if [[ $action == tunnel ]]; then
    exec ssh -F /dev/null "${ssh_options[@]}" -S none -N -o IdentitiesOnly=yes \
      -o ExitOnForwardFailure=yes -i "$ops_key" -L 127.0.0.1:12053:127.0.0.1:2053 "ops@$host"
  fi
  if ! ops_ssh "ops@$host" true 2>/dev/null; then ssh-add -t 900 "$ops_key"; fi
  if [[ $action == status ]]; then show_status; exit 0; fi
  ops_ssh -tt "ops@$host" 'sudo cat /etc/x-ui/vpn-control-access'
  exit 0
fi

root_key=()
if [[ $# == 1 ]]; then
  [[ -r $1 ]] || { echo 'Ключ root недоступен.' >&2; exit 2; }
  root_key=(-i "$1" -o IdentitiesOnly=yes)
fi
if [[ $action == install && -r $ops_key && -r $ops_key.pub ]]; then
  load_ops_key
  installed=$(ops_ssh "ops@$host" 'cat /etc/vpn-control-role' 2>/dev/null) || installed=
  if [[ -n $installed ]]; then
    [[ $installed == "$role" ]] || { echo "Сервер уже установлен в роли $installed." >&2; exit 1; }
    show_status
    echo 'Установка уже выполнена. Настройки и пароль сохранены.'
    exit 0
  fi
fi

workdir=$(mktemp -d /tmp/vpn-control.XXXXXXXX)
socket="$workdir/ssh"
root_ssh() {
  ssh "${ssh_options[@]}" -S "$socket" -o ClearAllForwardings=yes -o BatchMode=yes "$@"
}
cleanup() {
  if [[ -S $socket ]]; then
    root_ssh -O exit "root@$host" >/dev/null 2>&1 || true
  fi
  rmdir "$workdir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Проверка Ubuntu 24.04. Роль: %s.\n' "$role"
ssh "${ssh_options[@]}" ${root_key[@]+"${root_key[@]}"} -o ClearAllForwardings=yes -M -S "$socket" -fNT "root@$host"
root_ssh "root@$host" "bash -se -- $role $action" <<'REMOTE'
export LC_ALL=C
role=$1
action=$2
. /etc/os-release
if [[ $ID != ubuntu || $VERSION_ID != 24.04 || $(uname -m) != x86_64 || $(id -u) != 0 ]]; then
  echo 'Ожидается чистый сервер Ubuntu 24.04 x86_64 и подключение root.' >&2
  exit 1
fi
if [[ $(ufw status) != 'Status: inactive' || -e /etc/ssh/sshd_config.d/00-vpn-control.conf ]]; then
  echo 'SSH или UFW уже настроены. Требуется проверить текущее состояние.' >&2
  exit 1
fi
rules=$(ufw show added)
if ! grep -qx 'IPV6=yes' /etc/default/ufw || awk '/^ufw / && $0 != "ufw allow 22/tcp" { found=1 } END { exit !found }' <<< "$rules"; then
  echo 'Обнаружены нестандартные настройки UFW.' >&2
  exit 1
fi

if [[ $action == preflight ]]; then
  printf '%s (%s)\n' "$PRETTY_NAME" "$(uname -m)"
  nproc
  free -h
  df -h /
  ss -lntup
  if [[ -n $(ss -H -ltn '( sport = :2053 )') ]]; then
    echo 'Порт панели 2053 уже занят.' >&2
    exit 1
  fi
  echo 'Базовая проверка пройдена. Настройки не изменены.'
  exit 0
fi

echo '1/5. Обновление системы и установка пакетов для выбранной роли.'
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
apt-get update -o APT::Update::Error-Mode=any
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
packages=(ca-certificates curl openssl python3)
if [[ $role == controller ]]; then packages+=(postgresql); fi
apt-get -y install "${packages[@]}"
if [[ $role == controller ]]; then
  runuser -u postgres -- pg_isready
  test "$(runuser -u postgres -- psql -XAtqc 'SHOW listen_addresses;')" = localhost
fi
REMOTE
if [[ $action == preflight ]]; then exit 0; fi

echo '2/5. Создание ops и проверка SSH-ключа и sudo.'
if [[ ! -e $ops_key && ! -e $ops_key.pub ]]; then
  mkdir -p -m 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -f "$ops_key" -C ru-vps-ops
fi
[[ -r $ops_key && -r $ops_key.pub ]] || { echo 'Нужны обе части ключа ru-vps-ops.' >&2; exit 1; }
ssh-keygen -lf "$ops_key.pub" >/dev/null
load_ops_key

root_ssh -tt "root@$host" 'id -u ops >/dev/null 2>&1 || adduser --gecos "" ops'
root_ssh "root@$host" 'usermod -aG sudo ops'
root_ssh "root@$host" 'runuser -u ops -- bash -se -c '\''
  umask 077
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
  IFS= read -r key
  grep -Fxq -- "$key" "$HOME/.ssh/authorized_keys" || printf "\n%s\n" "$key" >> "$HOME/.ssh/authorized_keys"
'\''' < "$ops_key.pub"
ops_ssh -tt "ops@$host" 'sudo -k && sudo -v && sudo id -u'

echo '3/5. Установка 3X-UI v3.11.0 и проверка панели.'
root_ssh "root@$host" "bash -se -- $role" <<'REMOTE'
set -euo pipefail
umask 077
role=$1
version=3.11.0
archive=x-ui-linux-amd64.tar.gz
sha256=0ddfa4702f595442e2962acd81addc768fdacaa4ff2672c971a0463dae744916
dir=/usr/local/x-ui
state=/etc/x-ui
access=$state/vpn-control-access
unit=/etc/systemd/system/x-ui.service

exec 9>/run/lock/vpn-control-3x-ui.lock
flock -n 9 || { echo 'Установка панели уже запущена.' >&2; exit 1; }

check_panel() {
  local endpoint=$1 sockets
  systemctl is-active --quiet x-ui.service || return 1
  sockets=$(ss -H -ltn '( sport = :2053 )') || return 1
  [[ $(awk '{print $4}' <<< "$sockets") == 127.0.0.1:2053 ]] || return 1
  curl --noproxy '*' --max-time 5 --fail --silent --output /dev/null \
    "http://127.0.0.1:2053/$endpoint/csrf-token"
}

if [[ -f $access && ! -L $access ]]; then
  path=$(sed -n 's|^URL=http://127\.0\.0\.1:12053/\([a-f0-9]\{32\}\)/$|\1|p' "$access")
  if [[ $path =~ ^[a-f0-9]{32}$ ]] && grep -Fxq "VERSION=$version" "$access" \
    && grep -Fxq "ROLE=$role" "$access" && check_panel "$path"; then
    echo 'Панель уже установлена и прошла проверку. Пароль сохранён.'
    exit 0
  fi
  echo 'Найдена панель, которая не прошла проверку. Существующие данные сохранены.' >&2
  exit 1
fi
for target in "$dir" "$state" "$unit" /etc/default/x-ui /usr/bin/x-ui; do
  if [[ -e $target || -L $target ]]; then
    echo "Найдена существующая установка: $target" >&2
    exit 1
  fi
done
[[ -z $(ss -H -ltn '( sport = :2053 )') ]] || { echo 'Порт 2053 занят.' >&2; exit 1; }

tmp=$(mktemp -d /usr/local/.vpn-control-xui.XXXXXXXX)
changed=0
cleanup_panel() {
  if (( changed )); then
    echo 'Установка не завершилась. Удаляю файлы новой панели.' >&2
    systemctl disable --now x-ui.service >/dev/null 2>&1 || true
    rm -f -- "$unit" /usr/bin/x-ui
    rm -rf -- "$dir" "$state"
    systemctl daemon-reload || true
  fi
  rm -rf -- "$tmp"
}
trap cleanup_panel EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --retry 2 --connect-timeout 15 --max-time 300 \
  --output "$tmp/$archive" "https://github.com/MHSanaei/3x-ui/releases/download/v$version/$archive"
(cd "$tmp" && printf '%s  %s\n' "$sha256" "$archive" | sha256sum -c -)
tar --no-same-owner -xzf "$tmp/$archive" -C "$tmp"
test -x "$tmp/x-ui/x-ui"
test -x "$tmp/x-ui/bin/xray-linux-amd64"
test -s "$tmp/x-ui/x-ui.service.debian"
if [[ $role == node ]]; then
  xray_version=$("$tmp/x-ui/bin/xray-linux-amd64" version)
  printf '%s\n' "$xray_version" | sed -n '1p'
fi

changed=1
mv -T -- "$tmp/x-ui" "$dir"
install -d -m 700 "$state" /var/log/x-ui
install -m 755 "$dir/x-ui.sh" /usr/bin/x-ui
password=$(openssl rand -hex 24)
path=$(openssl rand -hex 16)
settings=$(cd "$dir" && ./x-ui setting -username vpnadmin -password "$password" \
  -listenIP 127.0.0.1 -port 2053 -webBasePath "/$path/" -show -getListen)
grep -Fxq 'Username and password updated successfully' <<< "$settings"
grep -Fxq 'hasDefaultCredential: false' <<< "$settings"
grep -Fxq 'listenIP: 127.0.0.1' <<< "$settings"
grep -Fxq 'port: 2053' <<< "$settings"
grep -Fxq "webBasePath: /$path/" <<< "$settings"
unset settings

# У версии 3.11.0 нет CLI-команды для отключения сервера подписок.
python3 - "$state/x-ui.db" <<'PYTHON'
import sqlite3
import sys

with sqlite3.connect(f"file:{sys.argv[1]}?mode=rw", uri=True) as db:
    keys = ("subEnable", "subJsonEnable", "subClashEnable", "tgBotEnable")
    for key in keys:
        db.execute("DELETE FROM settings WHERE key = ?", (key,))
        db.execute("INSERT INTO settings (key, value) VALUES (?, 'false')", (key,))
PYTHON

install -m 644 "$dir/x-ui.service.debian" "$unit"
systemctl daemon-reload
systemctl start x-ui.service
for ((attempt=0; attempt<20; attempt++)); do
  if check_panel "$path"; then break; fi
  sleep 1
done
check_panel "$path" || { echo 'Панель не ответила на 127.0.0.1:2053.' >&2; exit 1; }
printf '%s\n' "$password" | python3 -c '
import http.cookiejar
import json
import sys
import urllib.request

base = f"http://127.0.0.1:2053/{sys.argv[1]}/"
client = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
)
with client.open(base + "csrf-token", timeout=5) as reply:
    token = json.load(reply)["obj"]
payload = json.dumps({"username": "vpnadmin", "password": sys.stdin.readline().strip()}).encode()
request = urllib.request.Request(base + "login", payload, {
    "Content-Type": "application/json",
    "X-CSRF-Token": token,
})
with client.open(request, timeout=5) as reply:
    if json.load(reply).get("success") is not True:
        sys.exit("Не удалось войти в панель с созданным паролем.")
' "$path"
systemctl enable x-ui.service
printf 'ROLE=%s\nVERSION=%s\nURL=http://127.0.0.1:12053/%s/\nLOGIN=vpnadmin\nPASSWORD=%s\n' \
  "$role" "$version" "$path" "$password" > "$access"
unset password
changed=0
REMOTE

if ! ops_ssh "ops@$host" 'true'; then
  ssh-add -t 900 "$ops_key"
  ops_ssh "ops@$host" 'true'
fi
echo '4/5. Настройка SSH и UFW с автоматическим откатом через 3 минуты, если проверка не пройдёт.'
root_ssh "root@$host" 'bash -se' <<'REMOTE'
export LC_ALL=C
conf=/etc/ssh/sshd_config.d/00-vpn-control.conf
test ! -e "$conf" && test ! -L "$conf"
test "$(ufw status)" = 'Status: inactive'
systemd-run --quiet --unit=vpn-control-access-rollback --on-active=3min --timer-property=AccuracySec=1s \
  /bin/bash -c 'rm -f /etc/ssh/sshd_config.d/00-vpn-control.conf; /usr/sbin/sshd -t && systemctl reload ssh.service; /usr/sbin/ufw disable'

cat > "$conf" <<'SSHD'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
SSHD
sshd -t
effective=$(sshd -T)
grep -qx 'permitrootlogin no' <<< "$effective"
grep -qx 'passwordauthentication no' <<< "$effective"
grep -qx 'kbdinteractiveauthentication no' <<< "$effective"
grep -qx 'pubkeyauthentication yes' <<< "$effective"
systemctl reload ssh.service

ufw allow 22/tcp
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
REMOTE

echo '5/5. Проверка нового SSH-соединения и итогового состояния.'
if ! ops_ssh "ops@$host" 'test "$(id -un)" = ops && systemctl is-active --quiet x-ui.service'; then
  echo 'Новое соединение или служба 3X-UI не прошли проверку. Дождись срабатывания отката.' >&2
  exit 1
fi
root_ssh "root@$host" "bash -se -- $role" <<'REMOTE'
export LC_ALL=C
role=$1
systemctl is-active --quiet vpn-control-access-rollback.timer
test -f /etc/ssh/sshd_config.d/00-vpn-control.conf
status=$(ufw status verbose)
grep -qx 'Status: active' <<< "$status"
if [[ $role == controller ]]; then pg_isready; fi
systemctl stop vpn-control-access-rollback.timer
printf '%s\n' "$role" > /etc/vpn-control-role
chmod 644 /etc/vpn-control-role
printf '%s\n' "$status"
ss -ltn '( sport = :2053 or sport = :5432 )'
if [[ -e /var/run/reboot-required ]]; then
  echo 'Требуется перезагрузка. Выполни её отдельно после проверки доступа.'
fi
REMOTE
printf 'Готово. Получить адрес и пароль: bash %q credentials %q\n' "$0" "$host"
printf 'Открыть туннель: bash %q tunnel %q\n' "$0" "$host"
