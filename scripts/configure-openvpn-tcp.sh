#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

vpnica_require_root

ENV_FILE="$PROJECT_ROOT/.env"
UDP_ENV="$PROJECT_ROOT/config/openvpn/vpn.env"
UDP_CONFIG="$PROJECT_ROOT/state/openvpn/server/server.conf"
TCP_ENV="$PROJECT_ROOT/config/openvpn/vpn-tcp.env"
TCP_CONFIG="$PROJECT_ROOT/config/openvpn/server-tcp.conf"

[[ -f "$ENV_FILE" ]] || vpnica_die "Файл .env не найден."
[[ -f "$UDP_ENV" ]] || vpnica_die "Конфигурация OpenVPN UDP не найдена."
[[ -f "$UDP_CONFIG" ]] || vpnica_die "Серверная конфигурация OpenVPN UDP не найдена."

set -a
source "$ENV_FILE"
set +a

: "${OPENVPN_TCP_PORT:=443}"

temporary_env="$(mktemp "${TCP_ENV}.XXXXXX")"
temporary_config="$(mktemp "${TCP_CONFIG}.XXXXXX")"
trap 'rm -f -- "$temporary_env" "$temporary_config"' EXIT

sed \
  -e 's/^VPN_PROTO=.*/VPN_PROTO=tcp/' \
  -e "s/^VPN_PORT=.*/VPN_PORT=$OPENVPN_TCP_PORT/" \
  "$UDP_ENV" > "$temporary_env"

sed \
  -e "s/^port[[:space:]].*/port $OPENVPN_TCP_PORT/" \
  -e 's/^proto[[:space:]].*/proto tcp-server/' \
  -e 's/^ifconfig-pool-persist[[:space:]].*/ifconfig-pool-persist ipp-tcp.txt/' \
  -e '/^explicit-exit-notify/d' \
  "$UDP_CONFIG" > "$temporary_config"

chmod 600 "$temporary_env" "$temporary_config"
mv "$temporary_env" "$TCP_ENV"
mv "$temporary_config" "$TCP_CONFIG"
trap - EXIT
