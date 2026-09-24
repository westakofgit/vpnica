#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Сначала создайте .env из .env.example." >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

: "${VPNICA_PUBLIC_HOST:?VPNICA_PUBLIC_HOST is required}"
: "${OPENVPN_PORT:?OPENVPN_PORT is required}"
: "${OPENVPN_FIRST_CLIENT:?OPENVPN_FIRST_CLIENT is required}"
: "${TELEMT_PORT:?TELEMT_PORT is required}"
: "${TELEMT_TLS_DOMAIN:?TELEMT_TLS_DOMAIN is required}"

umask 077
mkdir -p \
  "$PROJECT_ROOT/backups" \
  "$PROJECT_ROOT/config/openvpn" \
  "$PROJECT_ROOT/config/routes" \
  "$PROJECT_ROOT/outputs/clients" \
  "$PROJECT_ROOT/state/openvpn" \
  "$PROJECT_ROOT/state/routes" \
  "$PROJECT_ROOT/state/telemt"

touch \
  "$PROJECT_ROOT/config/routes/manual-cidrs.txt" \
  "$PROJECT_ROOT/config/routes/manual-domains.txt" \
  "$PROJECT_ROOT/config/routes/manual-wildcards.txt"

OPENVPN_ENV="$PROJECT_ROOT/config/openvpn/vpn.env"
if [[ ! -e "$OPENVPN_ENV" ]]; then
  if [[ "$VPNICA_PUBLIC_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    OPENVPN_PUBLIC_ADDRESS="VPN_PUBLIC_IP=$VPNICA_PUBLIC_HOST"
  else
    OPENVPN_PUBLIC_ADDRESS="VPN_DNS_NAME=$VPNICA_PUBLIC_HOST"
  fi
  sed \
    -e "s|@PUBLIC_ADDRESS@|$OPENVPN_PUBLIC_ADDRESS|g" \
    -e "s|@OPENVPN_PORT@|$OPENVPN_PORT|g" \
    -e "s|@FIRST_CLIENT@|$OPENVPN_FIRST_CLIENT|g" \
    "$PROJECT_ROOT/config/openvpn/vpn.env.example" > "$OPENVPN_ENV"
  chmod 600 "$OPENVPN_ENV"
fi

TELEMT_CONFIG="$PROJECT_ROOT/state/telemt/config.toml"
if [[ ! -e "$TELEMT_CONFIG" ]]; then
  TELEMT_SECRET="$(openssl rand -hex 16)"
  sed \
    -e "s|@PUBLIC_HOST@|$VPNICA_PUBLIC_HOST|g" \
    -e "s|@TELEMT_PORT@|$TELEMT_PORT|g" \
    -e "s|@TLS_DOMAIN@|$TELEMT_TLS_DOMAIN|g" \
    -e "s|@TELEMT_SECRET@|$TELEMT_SECRET|g" \
    "$PROJECT_ROOT/config/telemt/config.toml.example" > "$TELEMT_CONFIG"
fi
chmod 600 "$TELEMT_CONFIG"

echo "Конфигурация создана. Существующие ключи и настройки не изменялись."
