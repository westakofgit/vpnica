#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="$PROJECT_ROOT/backups"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$BACKUP_DIR/vpnica-$STAMP.tar.gz.enc"

umask 077
mkdir -p "$BACKUP_DIR"

tar -C "$PROJECT_ROOT" -czf - \
  .env \
  config/openvpn/vpn.env \
  config/routes \
  state | openssl enc -aes-256-cbc -salt -pbkdf2 -out "$OUTPUT"

chmod 600 "$OUTPUT"
echo "$OUTPUT"
