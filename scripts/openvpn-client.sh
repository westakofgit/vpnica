#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Использование: $0 <имя-клиента>" >&2
  exit 1
fi

CLIENT_NAME="$1"
if [[ ! "$CLIENT_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Имя может содержать только A-Z, a-z, 0-9, дефис и подчёркивание." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/outputs/clients"
mkdir -p "$OUTPUT_DIR"
umask 077

if ! docker exec vpnica-openvpn test -f "/etc/openvpn/server/easy-rsa/pki/issued/${CLIENT_NAME}.crt"; then
  docker exec vpnica-openvpn ovpn_manage --addclient "$CLIENT_NAME"
fi

OUTPUT_PATH="$OUTPUT_DIR/$CLIENT_NAME.ovpn"
if [[ -e "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$OUTPUT_DIR/${CLIENT_NAME}-$(date -u +%Y%m%dT%H%M%SZ).ovpn"
fi

docker exec vpnica-openvpn ovpn_manage --exportclient "$CLIENT_NAME" > "$OUTPUT_PATH"
chmod 600 "$OUTPUT_PATH"
echo "$OUTPUT_PATH"
