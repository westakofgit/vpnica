#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

vpnica_require_root

validate_port() {
  [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]]
}

load_service_ports() {
  local env_file="$PROJECT_ROOT/.env"
  [[ -f "$env_file" ]] || vpnica_die "Файл $env_file не найден."

  OPENVPN_PORT="$(sed -nE 's/^OPENVPN_PORT=([0-9]+)$/\1/p' "$env_file" | head -n 1)"
  TELEMT_PORT="$(sed -nE 's/^TELEMT_PORT=([0-9]+)$/\1/p' "$env_file" | head -n 1)"
  validate_port "$OPENVPN_PORT" || vpnica_die "Некорректный OPENVPN_PORT."
  validate_port "$TELEMT_PORT" || vpnica_die "Некорректный TELEMT_PORT."
}

ssh_ports() {
  local server_port=""

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    server_port="$(awk '{print $4}' <<< "$SSH_CONNECTION")"
    if validate_port "$server_port"; then
      printf '%s\n' "$server_port"
    fi
  fi

  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }'
  fi
}

apply_host_firewall() {
  local ports
  local port

  command -v ufw >/dev/null 2>&1 || vpnica_die "UFW не установлен."
  load_service_ports

  ports="$(ssh_ports | awk '/^[0-9]+$/ && !seen[$0]++')"
  [[ -n "$ports" ]] || ports="22"

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  while IFS= read -r port; do
    validate_port "$port" || continue
    ufw allow "$port/tcp" comment 'vpnica SSH' >/dev/null
  done <<< "$ports"

  ufw allow "$TELEMT_PORT/tcp" comment 'vpnica Telemt' >/dev/null
  ufw allow "$OPENVPN_PORT/udp" comment 'vpnica OpenVPN' >/dev/null
  ufw --force enable >/dev/null
}

apply_docker_rules_for() {
  local tool="$1"

  command -v "$tool" >/dev/null 2>&1 || return 0
  "$tool" -nL DOCKER-USER >/dev/null 2>&1 || return 0

  "$tool" -N VPNICA-DOCKER >/dev/null 2>&1 || true
  "$tool" -F VPNICA-DOCKER
  "$tool" -C DOCKER-USER -j VPNICA-DOCKER >/dev/null 2>&1 || \
    "$tool" -I DOCKER-USER 1 -j VPNICA-DOCKER

  "$tool" -A VPNICA-DOCKER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
  "$tool" -A VPNICA-DOCKER -i docker0 -j RETURN
  "$tool" -A VPNICA-DOCKER -i 'br+' -j RETURN
  "$tool" -A VPNICA-DOCKER -p tcp -m conntrack --ctorigdstport "$TELEMT_PORT" -j RETURN
  "$tool" -A VPNICA-DOCKER -p udp -m conntrack --ctorigdstport "$OPENVPN_PORT" -j RETURN
  "$tool" -A VPNICA-DOCKER -o docker0 -j DROP
  "$tool" -A VPNICA-DOCKER -o 'br+' -j DROP
  "$tool" -A VPNICA-DOCKER -j RETURN
}

apply_docker_firewall() {
  load_service_ports
  apply_docker_rules_for iptables
  apply_docker_rules_for ip6tables
}

install_firewall_service() {
  install -m 0644 \
    "$PROJECT_ROOT/config/systemd/vpnica-firewall.service" \
    /etc/systemd/system/vpnica-firewall.service
  systemctl daemon-reload
  systemctl enable vpnica-firewall.service >/dev/null
  apply_docker_firewall
}

share_open() {
  local port="$1"
  validate_port "$port" || vpnica_die "Некорректный TCP-порт: $port"

  iptables -N VPNICA-SHARE >/dev/null 2>&1 || true
  iptables -F VPNICA-SHARE
  iptables -C INPUT -j VPNICA-SHARE >/dev/null 2>&1 || \
    iptables -I INPUT 1 -j VPNICA-SHARE
  iptables -A VPNICA-SHARE -p tcp --dport "$port" -j ACCEPT
}

share_close() {
  local port="$1"
  validate_port "$port" || vpnica_die "Некорректный TCP-порт: $port"

  if iptables -nL VPNICA-SHARE >/dev/null 2>&1; then
    iptables -F VPNICA-SHARE
    while iptables -C INPUT -j VPNICA-SHARE >/dev/null 2>&1; do
      iptables -D INPUT -j VPNICA-SHARE
    done
    iptables -X VPNICA-SHARE >/dev/null 2>&1 || true
  fi
}

show_status() {
  echo "UFW:"
  ufw status verbose
  echo
  echo "Docker:"
  iptables -S VPNICA-DOCKER 2>/dev/null || echo "Цепочка VPNICA-DOCKER ещё не создана."
  echo
  echo "Временное скачивание:"
  iptables -S VPNICA-SHARE 2>/dev/null || echo "Порт закрыт."
}

case "${1:-}" in
  apply)
    [[ $# -eq 1 ]] || vpnica_die "Использование: firewall.sh apply"
    apply_host_firewall
    install_firewall_service
    ;;
  docker-apply)
    [[ $# -eq 1 ]] || vpnica_die "Использование: firewall.sh docker-apply"
    apply_docker_firewall
    ;;
  share-open)
    [[ $# -eq 2 ]] || vpnica_die "Использование: firewall.sh share-open <порт>"
    share_open "$2"
    ;;
  share-close)
    [[ $# -eq 2 ]] || vpnica_die "Использование: firewall.sh share-close <порт>"
    share_close "$2"
    ;;
  status)
    [[ $# -eq 1 ]] || vpnica_die "Использование: firewall.sh status"
    show_status
    ;;
  *)
    vpnica_die "Использование: firewall.sh apply|docker-apply|share-open <порт>|share-close <порт>|status"
    ;;
esac
