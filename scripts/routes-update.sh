#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите этот скрипт от root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Файл .env не найден." >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

: "${IPLIST_URL:?IPLIST_URL is required}"
: "${RUSSIA_IPLIST_URL:=https://russia.iplist.opencck.org/?format=text&data=cidr4}"
: "${IPLIST_EXACT_MAX_ROUTES:=5000}"
: "${RUSSIA_MAX_ROUTES:=3000}"
: "${WILDCARD_DISCOVERY_URL:=https://crt.sh/}"
: "${WILDCARD_MAX_HOSTS:=1000}"

ROUTE_DIR="$PROJECT_ROOT/config/routes"
CACHE_DIR="$PROJECT_ROOT/state/routes"
SERVER_DIR="$PROJECT_ROOT/state/openvpn/server"
SERVER_CONFIG="$SERVER_DIR/server.conf"
CCD_DIR="$SERVER_DIR/ccd"
CCD_EXACT_FILE="$CCD_DIR/family-split-exact"
CCD_RUSSIA_DIRECT_FILE="$CCD_DIR/family-russia-direct"
MANUAL_DOMAINS="$ROUTE_DIR/manual-domains.txt"
MANUAL_WILDCARDS="$ROUTE_DIR/manual-wildcards.txt"
MANUAL_CIDRS="$ROUTE_DIR/manual-cidrs.txt"

mkdir -p "$ROUTE_DIR" "$CACHE_DIR" "$CCD_DIR"
touch "$MANUAL_DOMAINS" "$MANUAL_WILDCARDS" "$MANUAL_CIDRS"
chmod 755 "$CCD_DIR"

TEMP_DIR="$(mktemp -d "$CACHE_DIR/update.XXXXXX")"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

OPENCCK_FILE="$TEMP_DIR/opencck-cidr4.txt"
RUSSIA_FILE="$TEMP_DIR/russia-cidr4.txt"
OPENCCK_CACHE="$CACHE_DIR/opencck-cidr4.txt"
RUSSIA_CACHE="$CACHE_DIR/russia-cidr4.txt"
RESOLVED_FILE="$TEMP_DIR/resolved-ipv4.txt"
WILDCARD_HOSTS_FILE="$TEMP_DIR/wildcard-hosts.txt"
GENERATED_EXACT_FILE="$TEMP_DIR/family-split-exact"
GENERATED_RUSSIA_DIRECT_FILE="$TEMP_DIR/family-russia-direct"

if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 \
  "$IPLIST_URL" -o "$OPENCCK_FILE"; then
  [[ -s "$OPENCCK_CACHE" ]] || exit 1
  echo "Не удалось обновить OpenCCK; используется сохранённый список." >&2
  cp -p "$OPENCCK_CACHE" "$OPENCCK_FILE"
fi
if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 \
  "$RUSSIA_IPLIST_URL" -o "$RUSSIA_FILE"; then
  [[ -s "$RUSSIA_CACHE" ]] || exit 1
  echo "Не удалось обновить российские сети; используется сохранённый список." >&2
  cp -p "$RUSSIA_CACHE" "$RUSSIA_FILE"
fi

: > "$WILDCARD_HOSTS_FILE"
while IFS= read -r RAW_LINE || [[ -n "$RAW_LINE" ]]; do
  WILDCARD="${RAW_LINE%%#*}"
  WILDCARD="${WILDCARD//[[:space:]]/}"
  [[ -z "$WILDCARD" ]] && continue
  if [[ "$WILDCARD" != \*.* ]]; then
    echo "Некорректная маска поддоменов: $WILDCARD" >&2
    exit 1
  fi

  BASE_DOMAIN="${WILDCARD:2}"
  CACHE_FILE="$CACHE_DIR/wildcard-$BASE_DOMAIN.txt"
  RESPONSE_FILE="$TEMP_DIR/wildcard-$BASE_DOMAIN.json"
  DISCOVERED_FILE="$TEMP_DIR/wildcard-$BASE_DOMAIN.txt"

  if curl -fsSLG --retry 2 --connect-timeout 15 --max-time 120 \
    --data-urlencode "q=%.${BASE_DOMAIN}" \
    --data-urlencode "output=json" \
    "$WILDCARD_DISCOVERY_URL" -o "$RESPONSE_FILE" && \
    python3 - "$RESPONSE_FILE" "$BASE_DOMAIN" "$WILDCARD_MAX_HOSTS" > "$DISCOVERED_FILE" <<'PY'
import json
import re
import sys

source_path, base_domain, limit_raw = sys.argv[1:]
limit = int(limit_raw)
if not 1 <= limit <= 10000:
    raise SystemExit("WILDCARD_MAX_HOSTS должен быть от 1 до 10000")

domain_re = re.compile(r"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$")
with open(source_path, encoding="utf-8") as source:
    records = json.load(source)

hosts = {base_domain}
for record in records:
    for field in ("name_value", "common_name"):
        for raw_host in str(record.get(field, "")).splitlines():
            host = raw_host.strip().lower().rstrip(".")
            if host.startswith("*."):
                host = host[2:]
            if domain_re.fullmatch(host) and (host == base_domain or host.endswith("." + base_domain)):
                hosts.add(host)

ordered = [base_domain] + sorted(host for host in hosts if host != base_domain)
if len(ordered) > limit:
    print(
        f"Для *.{base_domain} найдено {len(ordered)} имён; используются первые {limit}",
        file=sys.stderr,
    )
for host in ordered[:limit]:
    print(host)
PY
  then
    install -m 0644 "$DISCOVERED_FILE" "$CACHE_FILE"
  elif [[ -f "$CACHE_FILE" ]]; then
    echo "Не удалось обновить *.$BASE_DOMAIN; используется сохранённый список." >&2
  else
    echo "Не удалось получить поддомены *.$BASE_DOMAIN; будет добавлен только $BASE_DOMAIN." >&2
    printf '%s\n' "$BASE_DOMAIN" > "$CACHE_FILE"
  fi

  cat "$CACHE_FILE" >> "$WILDCARD_HOSTS_FILE"
done < "$MANUAL_WILDCARDS"

: > "$RESOLVED_FILE"
while IFS= read -r RAW_LINE || [[ -n "$RAW_LINE" ]]; do
  DOMAIN="${RAW_LINE%%#*}"
  DOMAIN="${DOMAIN//[[:space:]]/}"
  [[ -z "$DOMAIN" ]] && continue
  getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u >> "$RESOLVED_FILE" || true
done < <(cat "$MANUAL_DOMAINS" "$WILDCARD_HOSTS_FILE")

python3 - \
  "$OPENCCK_FILE" \
  "$RUSSIA_FILE" \
  "$MANUAL_CIDRS" \
  "$RESOLVED_FILE" \
  "$GENERATED_EXACT_FILE" \
  "$GENERATED_RUSSIA_DIRECT_FILE" \
  "$IPLIST_EXACT_MAX_ROUTES" \
  "$RUSSIA_MAX_ROUTES" <<'PY'
import ipaddress
import pathlib
import sys

(
    opencck_path,
    russia_path,
    manual_path,
    resolved_path,
    exact_output_path,
    russia_output_path,
    exact_max_routes_raw,
    russia_max_routes_raw,
) = sys.argv[1:]
exact_max_routes = int(exact_max_routes_raw)
russia_max_routes = int(russia_max_routes_raw)
if not 100 <= exact_max_routes <= 10000:
    raise SystemExit("IPLIST_EXACT_MAX_ROUTES должен быть от 100 до 10000")
if not 100 <= russia_max_routes <= 10000:
    raise SystemExit("RUSSIA_MAX_ROUTES должен быть от 100 до 10000")

def read_networks(path):
    result = []
    for number, raw in enumerate(pathlib.Path(path).read_text().splitlines(), 1):
        value = raw.split("#", 1)[0].strip()
        if not value:
            continue
        try:
            network = ipaddress.ip_network(value, strict=False)
        except ValueError as error:
            raise SystemExit(f"Некорректная запись {path}:{number}: {value}: {error}")
        if network.version != 4:
            continue
        result.append(network)
    return result

opencck = read_networks(opencck_path)
if len(opencck) < 100:
    raise SystemExit("Выгрузка opencck слишком мала; текущие маршруты сохранены")
russia = read_networks(russia_path)
if len(russia) < 100:
    raise SystemExit("Выгрузка российских сетей слишком мала; текущие маршруты сохранены")

manual = read_networks(manual_path)
manual += read_networks(resolved_path)
manual += [ipaddress.ip_network("1.1.1.1/32"), ipaddress.ip_network("9.9.9.9/32")]
exact = list(ipaddress.collapse_addresses(opencck + manual))
russia = list(ipaddress.collapse_addresses(russia))

if len(exact) > exact_max_routes:
    raise SystemExit(
        f"Точный список содержит {len(exact)} маршрутов, лимит — {exact_max_routes}"
    )
if len(russia) > russia_max_routes:
    raise SystemExit(
        f"Российский список содержит {len(russia)} маршрутов, лимит — {russia_max_routes}"
    )

exact_lines = [
    "# Generated by scripts/routes-update.sh",
    '# Exact OpenCCK networks; no broadening',
    'push-remove "redirect-gateway"',
]
for network in exact:
    exact_lines.append(f'push "route {network.network_address} {network.netmask}"')
pathlib.Path(exact_output_path).write_text("\n".join(exact_lines) + "\n")
print(f"Подготовлено точных маршрутов OpenCCK: {len(exact)}")

russia_lines = [
    "# Generated by scripts/routes-update.sh",
    "# Full tunnel with Russian IPv4 networks bypassing VPN",
]
for network in russia:
    russia_lines.append(
        f'push "route {network.network_address} {network.netmask} net_gateway"'
    )
pathlib.Path(russia_output_path).write_text("\n".join(russia_lines) + "\n")
print(f"Подготовлено российских исключающих маршрутов: {len(russia)}")
PY

SERVER_CHANGED=0
if ! grep -Fxq 'client-config-dir ccd' "$SERVER_CONFIG"; then
  if [[ ! -e "$SERVER_CONFIG.pre-split" ]]; then
    cp -p "$SERVER_CONFIG" "$SERVER_CONFIG.pre-split"
  fi
  printf '\nclient-config-dir ccd\n' >> "$SERVER_CONFIG"
  SERVER_CHANGED=1
fi

for ROUTE_PAIR in \
  "$GENERATED_EXACT_FILE:$CCD_EXACT_FILE" \
  "$GENERATED_RUSSIA_DIRECT_FILE:$CCD_RUSSIA_DIRECT_FILE"
do
  GENERATED_ROUTE_FILE="${ROUTE_PAIR%%:*}"
  ACTIVE_ROUTE_FILE="${ROUTE_PAIR#*:}"
  if [[ ! -f "$ACTIVE_ROUTE_FILE" ]] || ! cmp -s "$GENERATED_ROUTE_FILE" "$ACTIVE_ROUTE_FILE"; then
    install -m 0644 "$GENERATED_ROUTE_FILE" "$ACTIVE_ROUTE_FILE"
    SERVER_CHANGED=1
  fi
done

install -m 0644 "$OPENCCK_FILE" "$OPENCCK_CACHE"
install -m 0644 "$RUSSIA_FILE" "$RUSSIA_CACHE"

if [[ "$SERVER_CHANGED" -eq 1 ]]; then
  docker compose \
    --project-directory "$PROJECT_ROOT" \
    --env-file "$ENV_FILE" \
    -f "$PROJECT_ROOT/compose.yaml" \
    restart openvpn
  echo "Маршруты обновлены; OpenVPN-клиенты переподключаются."
else
  echo "Маршруты не изменились."
fi
