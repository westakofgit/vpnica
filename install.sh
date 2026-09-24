#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_ROOT="/opt/vpnica"
PUBLIC_HOST="auto"
RESTORE_FILE=""

usage() {
  cat <<'EOF'
Использование:
  install.sh [--host auto|домен|IPv4] [--restore backup.tar.gz.enc]

Без --restore создаётся новая установка с новыми ключами.
С --restore сохраняются существующие OpenVPN-сертификаты и secret Telemt.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      PUBLIC_HOST="$2"
      shift 2
      ;;
    --restore)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      RESTORE_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Неизвестный параметр: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите установщик от root." >&2
  exit 1
fi

if [[ -n "$RESTORE_FILE" && ! -f "$RESTORE_FILE" ]]; then
  echo "Архив не найден: $RESTORE_FILE" >&2
  exit 1
fi

"$SOURCE_ROOT/scripts/bootstrap-host.sh"

if [[ "$SOURCE_ROOT" != "$TARGET_ROOT" ]]; then
  install -d -m 0750 "$TARGET_ROOT"
  tar -C "$SOURCE_ROOT" -cf - \
    --exclude='.git' \
    --exclude='.DS_Store' \
    --exclude='.env' \
    --exclude='backups' \
    --exclude='outputs' \
    --exclude='state' \
    --exclude='config/openvpn/vpn.env' \
    --exclude='config/routes/manual-cidrs.txt' \
    --exclude='config/routes/manual-domains.txt' \
    --exclude='config/routes/manual-wildcards.txt' \
    . | tar -C "$TARGET_ROOT" -xf -
fi

chmod 0755 "$TARGET_ROOT/install.sh" "$TARGET_ROOT/scripts/"*.sh "$TARGET_ROOT/scripts/vpnica"
source "$TARGET_ROOT/scripts/common.sh"

if [[ "$PUBLIC_HOST" == "auto" ]]; then
  PUBLIC_HOST="$(curl -4fsSL --connect-timeout 10 --max-time 20 https://api.ipify.org)" || \
    vpnica_die "Не удалось определить публичный IPv4. Укажите --host явно."
fi
PUBLIC_HOST="$(vpnica_validate_host "$PUBLIC_HOST")" || \
  vpnica_die "Некорректный адрес: $PUBLIC_HOST"

if [[ -n "$RESTORE_FILE" ]]; then
  if [[ -d "$TARGET_ROOT/state" ]] && \
    [[ -n "$(find "$TARGET_ROOT/state" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    vpnica_die "В $TARGET_ROOT уже есть состояние. Восстановление разрешено только в новую установку."
  fi

  RESTORE_DIR="$(mktemp -d /tmp/vpnica-restore.XXXXXX)"
  trap 'rm -rf -- "$RESTORE_DIR"' EXIT
  "$TARGET_ROOT/scripts/restore.sh" "$RESTORE_FILE" "$RESTORE_DIR/data"
  cp -p "$RESTORE_DIR/data/.env" "$TARGET_ROOT/.env"
  install -d -m 0700 "$TARGET_ROOT/config/openvpn" "$TARGET_ROOT/config/routes" "$TARGET_ROOT/state"
  cp -p "$RESTORE_DIR/data/config/openvpn/vpn.env" "$TARGET_ROOT/config/openvpn/vpn.env"
  cp -a "$RESTORE_DIR/data/config/routes/." "$TARGET_ROOT/config/routes/"
  cp -a "$RESTORE_DIR/data/state/." "$TARGET_ROOT/state/"
else
  if [[ ! -f "$TARGET_ROOT/.env" ]]; then
    cp "$TARGET_ROOT/.env.example" "$TARGET_ROOT/.env"
    chmod 600 "$TARGET_ROOT/.env"
  fi
fi

vpnica_set_env_value "$TARGET_ROOT/.env" VPNICA_PUBLIC_HOST "$PUBLIC_HOST"
"$TARGET_ROOT/scripts/init-config.sh"
"$TARGET_ROOT/scripts/set-host.sh" --offline "$PUBLIC_HOST"

if ! docker inspect vpnica-openvpn >/dev/null 2>&1; then
  if ss -H -lun 'sport = :443' | grep -q .; then
    vpnica_die "UDP/443 уже занят другим процессом."
  fi
fi
if ! docker inspect vpnica-telemt >/dev/null 2>&1; then
  if ss -H -ltn 'sport = :443' | grep -q .; then
    vpnica_die "TCP/443 уже занят другим процессом."
  fi
fi

docker compose --project-directory "$TARGET_ROOT" up -d

openvpn_ready=0
for _ in $(seq 1 60); do
  if docker exec vpnica-openvpn test -d /etc/openvpn/server/easy-rsa/pki 2>/dev/null; then
    openvpn_ready=1
    break
  fi
  sleep 2
done
[[ "$openvpn_ready" -eq 1 ]] || vpnica_die "OpenVPN не успел подготовить PKI."

SERVER_CONFIG="$TARGET_ROOT/state/openvpn/server/server.conf"
if ! grep -Eq '^[[:space:]]*duplicate-cn([[:space:]]|$)' "$SERVER_CONFIG"; then
  if [[ ! -e "$SERVER_CONFIG.pre-family-profile" ]]; then
    cp -p "$SERVER_CONFIG" "$SERVER_CONFIG.pre-family-profile"
  fi
  printf '\nduplicate-cn\n' >> "$SERVER_CONFIG"
fi

for client in family family-split-exact family-russia-direct; do
  if ! docker exec vpnica-openvpn test -f "/etc/openvpn/server/easy-rsa/pki/issued/${client}.crt"; then
    docker exec vpnica-openvpn ovpn_manage --addclient "$client"
  fi
done

"$TARGET_ROOT/scripts/routes-update.sh"
"$TARGET_ROOT/scripts/install-route-timer.sh"
OUTPUT_DIR="$("$TARGET_ROOT/scripts/export-configs.sh")"

ln -sfn "$TARGET_ROOT/scripts/vpnica" /usr/local/sbin/vpnica

echo
echo "vpnica установлена."
echo "Адрес подключения: $PUBLIC_HOST"
echo "Профили и QR-код: $OUTPUT_DIR"
echo "Управление: vpnica help"
