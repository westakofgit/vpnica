#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Использование: $0 <файл-ссылки.txt> [qr-код.png]" >&2
  exit 1
fi

LINK_FILE="$1"
OUTPUT_PATH="${2:-${LINK_FILE%.*}-qr.png}"

if [[ ! -f "$LINK_FILE" ]]; then
  echo "Файл ссылки не найден: $LINK_FILE" >&2
  exit 1
fi

if ! command -v qrencode >/dev/null 2>&1; then
  echo "Установите пакет qrencode или повторно запустите scripts/bootstrap-host.sh." >&2
  exit 1
fi

if [[ -e "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="${OUTPUT_PATH%.png}-$(date -u +%Y%m%dT%H%M%SZ).png"
fi

umask 077
tr -d '\r\n' < "$LINK_FILE" | qrencode -o "$OUTPUT_PATH" -s 8 -m 4
chmod 600 "$OUTPUT_PATH"
echo "$OUTPUT_PATH"
