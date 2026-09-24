#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="westakofgit/vpnica"
REF="${VPNICA_REF:-main}"
ARCHIVE_URL="https://github.com/${REPOSITORY}/archive/refs/heads/${REF}.tar.gz"
TEMP_DIR="$(mktemp -d /tmp/vpnica-bootstrap.XXXXXX)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите загрузчик от root." >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || {
  echo "Для загрузки требуется curl." >&2
  exit 1
}

curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 \
  "$ARCHIVE_URL" -o "$TEMP_DIR/vpnica.tar.gz"
mkdir -p "$TEMP_DIR/source"
tar -xzf "$TEMP_DIR/vpnica.tar.gz" --strip-components=1 -C "$TEMP_DIR/source"
chmod 0755 "$TEMP_DIR/source/install.sh" "$TEMP_DIR/source/scripts/"*.sh "$TEMP_DIR/source/scripts/vpnica"

"$TEMP_DIR/source/install.sh" "$@"
