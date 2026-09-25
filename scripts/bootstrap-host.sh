#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите этот скрипт от root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  docker.io \
  docker-compose-v2 \
  jq \
  openssl \
  python3 \
  qrencode \
  ufw \
  zip

install -d -m 0750 /opt/vpnica
install -m 0644 "$PROJECT_ROOT/config/sysctl/99-vpnica.conf" /etc/sysctl.d/99-vpnica.conf
sysctl --system
systemctl enable --now docker

echo "Базовая система готова. Скопируйте проект в /opt/vpnica и выполните scripts/init-config.sh."
