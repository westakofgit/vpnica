#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

[[ $# -ge 2 ]] || {
  echo "Использование: share-session.sh <порт> <share-server.py> [параметры]" >&2
  exit 1
}

PORT="$1"
shift

cleanup() {
  "$SCRIPT_DIR/firewall.sh" share-close "$PORT" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

/usr/bin/python3 "$@"
