#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

vpnica_require_root

OFFLINE=0
if [[ "${1:-}" == "--offline" ]]; then
  OFFLINE=1
  shift
fi

[[ $# -eq 1 ]] || vpnica_die "Использование: $0 [--offline] <домен|IPv4>"
PUBLIC_HOST="$(vpnica_validate_host "$1")" || vpnica_die "Некорректный адрес: $1"
ENV_FILE="$PROJECT_ROOT/.env"
OPENVPN_ENV="$PROJECT_ROOT/config/openvpn/vpn.env"
TELEMT_CONFIG="$PROJECT_ROOT/state/telemt/config.toml"

[[ -f "$ENV_FILE" ]] || vpnica_die "Файл .env не найден."
vpnica_set_env_value "$ENV_FILE" VPNICA_PUBLIC_HOST "$PUBLIC_HOST"

if [[ -f "$OPENVPN_ENV" ]]; then
  temporary="$(mktemp "${OPENVPN_ENV}.XXXXXX")"
  if [[ "$PUBLIC_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    address_line="VPN_PUBLIC_IP=$PUBLIC_HOST"
  else
    address_line="VPN_DNS_NAME=$PUBLIC_HOST"
  fi
  {
    printf '%s\n' "$address_line"
    grep -Ev '^VPN_(PUBLIC_IP|DNS_NAME)=' "$OPENVPN_ENV" || true
  } > "$temporary"
  chmod --reference="$OPENVPN_ENV" "$temporary" 2>/dev/null || chmod 600 "$temporary"
  mv "$temporary" "$OPENVPN_ENV"
fi

if [[ -f "$PROJECT_ROOT/state/openvpn/server/client-common.txt" ]]; then
  sed -i -E \
    "s|^remote[[:space:]]+[^[:space:]]+[[:space:]]+([0-9]+)(.*)$|remote $PUBLIC_HOST \\1\\2|" \
    "$PROJECT_ROOT/state/openvpn/server/client-common.txt"
fi

for directory in "$PROJECT_ROOT/state/openvpn/clients" "$PROJECT_ROOT/outputs/clients"; do
  [[ -d "$directory" ]] || continue
  find "$directory" -maxdepth 1 -type f -name '*.ovpn' -exec \
    sed -i -E "s|^remote[[:space:]]+[^[:space:]]+[[:space:]]+([0-9]+)(.*)$|remote $PUBLIC_HOST \\1\\2|" {} +
done

if [[ -f "$TELEMT_CONFIG" ]]; then
  sed -i -E \
    "s|^[[:space:]]*public_host[[:space:]]*=.*$|public_host = \"$PUBLIC_HOST\"|" \
    "$TELEMT_CONFIG"
fi

if [[ "$OFFLINE" -eq 0 ]]; then
  if docker inspect vpnica-telemt >/dev/null 2>&1; then
    docker compose --project-directory "$PROJECT_ROOT" restart telemt
  fi
  if docker inspect vpnica-openvpn >/dev/null 2>&1; then
    "$SCRIPT_DIR/export-configs.sh"
  fi
fi

echo "Адрес подключения изменён на $PUBLIC_HOST. Ключи и сертификаты сохранены."
