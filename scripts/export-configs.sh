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
: "${OPENVPN_TCP_PORT:=443}"
: "${OPENVPN_TUN_MTU:=1300}"
: "${OPENVPN_MSSFIX:=1250}"
: "${TELEMT_PORT:?TELEMT_PORT is required}"

PUBLIC_HOST="$(vpnica_validate_host "$VPNICA_PUBLIC_HOST")" || \
  vpnica_die "Некорректный адрес: $VPNICA_PUBLIC_HOST"
OUTPUT_DIR="$PROJECT_ROOT/outputs/$PUBLIC_HOST"
TELEMT_CONFIG="$PROJECT_ROOT/state/telemt/config.toml"
CLIENTS=(family family-split-exact)
OUTPUT_NAMES=("${PUBLIC_HOST}-ovpn.ovpn" "${PUBLIC_HOST}-ovpn-split.ovpn")
TCP_OUTPUT_NAMES=("${PUBLIC_HOST}-ovpn-tcp.ovpn" "${PUBLIC_HOST}-ovpn-split-tcp.ovpn")

umask 077
mkdir -p "$OUTPUT_DIR"
rm -f -- \
  "$OUTPUT_DIR/family.ovpn" \
  "$OUTPUT_DIR/family-split-exact.ovpn" \
  "$OUTPUT_DIR/family-russia-direct.ovpn" \
  "$OUTPUT_DIR/ovpn-${PUBLIC_HOST}.ovpn" \
  "$OUTPUT_DIR/ovpn-${PUBLIC_HOST}-split.ovpn" \
  "$OUTPUT_DIR/ovpn-${PUBLIC_HOST}-tcp.ovpn" \
  "$OUTPUT_DIR/ovpn-${PUBLIC_HOST}-split-tcp.ovpn"

for index in "${!CLIENTS[@]}"; do
  client="${CLIENTS[$index]}"
  output_name="${OUTPUT_NAMES[$index]}"
  if ! docker exec vpnica-openvpn test -f "/etc/openvpn/server/easy-rsa/pki/issued/${client}.crt"; then
    vpnica_die "Не найден сертификат OpenVPN-клиента: $client"
  fi

  temporary="$OUTPUT_DIR/.${client}.ovpn.tmp"
  docker exec vpnica-openvpn ovpn_manage --exportclient "$client" > "$temporary"
  sed -i -E \
    "s|^remote[[:space:]]+[^[:space:]]+[[:space:]]+[0-9]+(.*)$|remote $PUBLIC_HOST $OPENVPN_PORT\\1|" \
    "$temporary"
  sed -i -E '/^(tun-mtu|mssfix)[[:space:]]+/d' "$temporary"
  sed -i "/^<ca>$/i tun-mtu $OPENVPN_TUN_MTU\nmssfix $OPENVPN_MSSFIX" "$temporary"
  mv "$temporary" "$OUTPUT_DIR/$output_name"
  chmod 600 "$OUTPUT_DIR/$output_name"

  tcp_output_name="${TCP_OUTPUT_NAMES[$index]}"
  cp "$OUTPUT_DIR/$output_name" "$OUTPUT_DIR/$tcp_output_name"
  sed -i -E \
    -e 's|^proto[[:space:]]+.*$|proto tcp-client|' \
    -e "s|^remote[[:space:]]+[^[:space:]]+[[:space:]]+[0-9]+(.*)$|remote $PUBLIC_HOST $OPENVPN_TCP_PORT\1|" \
    "$OUTPUT_DIR/$tcp_output_name"
  chmod 600 "$OUTPUT_DIR/$tcp_output_name"
done

[[ -f "$TELEMT_CONFIG" ]] || vpnica_die "Конфигурация Telemt не найдена."
TELEMT_SECRET="$(sed -nE 's/^[[:space:]]*owner[[:space:]]*=[[:space:]]*"([0-9a-fA-F]+)".*/\1/p' "$TELEMT_CONFIG" | head -n 1)"
TLS_DOMAIN="$(sed -nE 's/^[[:space:]]*tls_domain[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$TELEMT_CONFIG" | head -n 1)"

[[ "$TELEMT_SECRET" =~ ^[0-9a-fA-F]{32}$ ]] || \
  vpnica_die "Не удалось прочитать 32-символьный hex-секрет Telemt."
[[ -n "$TLS_DOMAIN" ]] || vpnica_die "Не удалось прочитать TLS-домен Telemt."

TLS_DOMAIN_HEX="$(printf '%s' "$TLS_DOMAIN" | od -An -tx1 | tr -d ' \n')"
TELEMT_SECRET_URL="ee${TELEMT_SECRET,,}${TLS_DOMAIN_HEX}"
HTTPS_LINK="https://t.me/proxy?server=${PUBLIC_HOST}&port=${TELEMT_PORT}&secret=${TELEMT_SECRET_URL}"

rm -f -- "$OUTPUT_DIR/telemt-link.txt"
printf '%s\n' "$HTTPS_LINK" > "$OUTPUT_DIR/telemt-https-link.txt"
qrencode -o "$OUTPUT_DIR/telemt-qr.png" -s 8 -m 4 "$HTTPS_LINK"
chmod 600 "$OUTPUT_DIR"/*

echo "$OUTPUT_DIR"
