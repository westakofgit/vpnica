#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

vpnica_require_root

ENV_FILE="$PROJECT_ROOT/.env"
[[ -f "$ENV_FILE" ]] || vpnica_die "Файл .env не найден."

set -a
source "$ENV_FILE"
set +a

: "${VPNICA_PUBLIC_HOST:?VPNICA_PUBLIC_HOST is required}"
: "${OPENVPN_PORT:?OPENVPN_PORT is required}"
: "${TELEMT_PORT:?TELEMT_PORT is required}"

PUBLIC_HOST="$(vpnica_validate_host "$VPNICA_PUBLIC_HOST")" || \
  vpnica_die "Некорректный адрес: $VPNICA_PUBLIC_HOST"
OUTPUT_DIR="$PROJECT_ROOT/outputs/$PUBLIC_HOST"
TELEMT_CONFIG="$PROJECT_ROOT/state/telemt/config.toml"
CLIENTS=(family family-split-exact family-russia-direct)

umask 077
mkdir -p "$OUTPUT_DIR"

for client in "${CLIENTS[@]}"; do
  if ! docker exec vpnica-openvpn test -f "/etc/openvpn/server/easy-rsa/pki/issued/${client}.crt"; then
    vpnica_die "Не найден сертификат OpenVPN-клиента: $client"
  fi

  temporary="$OUTPUT_DIR/.${client}.ovpn.tmp"
  docker exec vpnica-openvpn ovpn_manage --exportclient "$client" > "$temporary"
  sed -i -E \
    "s|^remote[[:space:]]+[^[:space:]]+[[:space:]]+[0-9]+(.*)$|remote $PUBLIC_HOST $OPENVPN_PORT\\1|" \
    "$temporary"
  mv "$temporary" "$OUTPUT_DIR/${client}.ovpn"
  chmod 600 "$OUTPUT_DIR/${client}.ovpn"
done

[[ -f "$TELEMT_CONFIG" ]] || vpnica_die "Конфигурация Telemt не найдена."
TELEMT_SECRET="$(sed -nE 's/^[[:space:]]*owner[[:space:]]*=[[:space:]]*"([0-9a-fA-F]+)".*/\1/p' "$TELEMT_CONFIG" | head -n 1)"
TLS_DOMAIN="$(sed -nE 's/^[[:space:]]*tls_domain[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$TELEMT_CONFIG" | head -n 1)"

[[ "$TELEMT_SECRET" =~ ^[0-9a-fA-F]{32}$ ]] || \
  vpnica_die "Не удалось прочитать 32-символьный hex-секрет Telemt."
[[ -n "$TLS_DOMAIN" ]] || vpnica_die "Не удалось прочитать TLS-домен Telemt."

TLS_DOMAIN_HEX="$(printf '%s' "$TLS_DOMAIN" | od -An -tx1 | tr -d ' \n')"
TELEMT_SECRET_URL="ee${TELEMT_SECRET,,}${TLS_DOMAIN_HEX}"
TG_LINK="tg://proxy?server=${PUBLIC_HOST}&port=${TELEMT_PORT}&secret=${TELEMT_SECRET_URL}"
HTTPS_LINK="https://t.me/proxy?server=${PUBLIC_HOST}&port=${TELEMT_PORT}&secret=${TELEMT_SECRET_URL}"

printf '%s\n' "$TG_LINK" > "$OUTPUT_DIR/telemt-link.txt"
printf '%s\n' "$HTTPS_LINK" > "$OUTPUT_DIR/telemt-https-link.txt"
qrencode -o "$OUTPUT_DIR/telemt-qr.png" -s 8 -m 4 "$TG_LINK"
chmod 600 "$OUTPUT_DIR"/*

echo "$OUTPUT_DIR"
