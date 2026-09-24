#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Использование: $0 <домен|*.домен|IPv4|CIDR>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ROUTE_DIR="$PROJECT_ROOT/config/routes"
ENTRY="${1,,}"

mkdir -p "$ROUTE_DIR"

if python3 -c 'import ipaddress, sys; ipaddress.IPv4Network(sys.argv[1], strict=False)' "$ENTRY" >/dev/null 2>&1; then
  TARGET="$ROUTE_DIR/manual-cidrs.txt"
else
  ENTRY="${ENTRY%.}"
  if [[ "$ENTRY" == \*.* ]]; then
    DOMAIN="${ENTRY:2}"
    TARGET="$ROUTE_DIR/manual-wildcards.txt"
  else
    ENTRY="${ENTRY#.}"
    DOMAIN="$ENTRY"
    TARGET="$ROUTE_DIR/manual-domains.txt"
  fi
  if [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
    echo "Укажите домен, маску *.домен без https:// и пути либо корректный IPv4/CIDR." >&2
    exit 1
  fi
fi

touch "$TARGET"
if ! grep -Fxq "$ENTRY" "$TARGET"; then
  printf '%s\n' "$ENTRY" >> "$TARGET"
  echo "Добавлено: $ENTRY"
else
  echo "Уже добавлено: $ENTRY"
fi

exec "$SCRIPT_DIR/routes-update.sh"
