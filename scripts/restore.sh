#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Использование: $0 <backup.tar.gz.enc> <новая-пустая-папка>" >&2
  exit 1
fi

BACKUP_FILE="$1"
DESTINATION="$2"

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "Архив не найден: $BACKUP_FILE" >&2
  exit 1
fi

if [[ -e "$DESTINATION" ]] && [[ -n "$(find "$DESTINATION" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "Папка назначения должна быть новой или пустой." >&2
  exit 1
fi

umask 077
mkdir -p "$DESTINATION"
openssl enc -d -aes-256-cbc -pbkdf2 -in "$BACKUP_FILE" | tar -C "$DESTINATION" -xzf -
echo "$DESTINATION"

