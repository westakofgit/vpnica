#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите этот скрипт от root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

install -m 0644 \
  "$PROJECT_ROOT/config/systemd/vpnica-routes-update.service" \
  /etc/systemd/system/vpnica-routes-update.service
install -m 0644 \
  "$PROJECT_ROOT/config/systemd/vpnica-routes-update.timer" \
  /etc/systemd/system/vpnica-routes-update.timer

systemctl daemon-reload
systemctl enable --now vpnica-routes-update.timer

echo "Ночное обновление маршрутов включено: 04:15 Europe/Moscow."
