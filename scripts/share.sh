#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

vpnica_require_root

ENV_FILE="$PROJECT_ROOT/.env"
[[ -f "$ENV_FILE" ]] || vpnica_die "Файл .env не найден."

set -a
source "$ENV_FILE"
set +a

: "${VPNICA_PUBLIC_HOST:?VPNICA_PUBLIC_HOST is required}"
PUBLIC_HOST="$(vpnica_validate_host "$VPNICA_PUBLIC_HOST")" || \
  vpnica_die "Некорректный адрес: $VPNICA_PUBLIC_HOST"

OUTPUT_DIR="$("$SCRIPT_DIR/export-configs.sh")"
SHARE_DIR="$PROJECT_ROOT/state/share"
STATE_FILE="$SHARE_DIR/current"
TTL_SECONDS=1800
MAX_DOWNLOADS=3

umask 077

if [[ -f "$STATE_FILE" ]]; then
  OLD_UNIT="$(sed -nE 's/^UNIT=(.+)$/\1/p' "$STATE_FILE" | head -n 1)"
  if [[ "$OLD_UNIT" =~ ^vpnica-share-[0-9a-f]{12}\.service$ ]]; then
    systemctl stop "$OLD_UNIT" >/dev/null 2>&1 || true
  fi
fi

rm -rf -- "$SHARE_DIR"
mkdir -p "$SHARE_DIR"
BUNDLE_DIR="$(mktemp -d "$SHARE_DIR/bundle.XXXXXX")"
trap 'rm -rf -- "$BUNDLE_DIR"' EXIT

for file in \
  family.ovpn \
  family-split-exact.ovpn \
  family-russia-direct.ovpn \
  telemt-link.txt \
  telemt-https-link.txt \
  telemt-qr.png; do
  [[ -f "$OUTPUT_DIR/$file" ]] || vpnica_die "Не найден файл: $OUTPUT_DIR/$file"
  install -m 0600 "$OUTPUT_DIR/$file" "$BUNDLE_DIR/$file"
done

TELEMT_LINK="$(<"$OUTPUT_DIR/telemt-https-link.txt")"
TELEMT_LINK_HTML="$(printf '%s' "$TELEMT_LINK" | sed 's/&/\&amp;/g')"

cat > "$BUNDLE_DIR/README.txt" <<EOF
VPNICA — готовый комплект подключения

OpenVPN:
1. family.ovpn — весь IPv4-трафик через VPN.
2. family-split-exact.ovpn — через VPN только адреса из обновляемого списка и ручные добавления.
3. family-russia-direct.ovpn — российские IPv4-сети напрямую, остальной IPv4-трафик через VPN.

Импортируйте нужный файл .ovpn в OpenVPN Connect или в ваш роутер.

Telegram-прокси Telemt:
$TELEMT_LINK

Также можно открыть telemt-qr.png и отсканировать QR-код.

Файлы содержат действующие ключи доступа. Не публикуйте и не пересылайте комплект посторонним.
EOF

cat > "$BUNDLE_DIR/START-HERE.html" <<EOF
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>VPNICA — начало работы</title>
  <style>
    body { max-width: 760px; margin: 40px auto; padding: 0 20px; font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: #172033; }
    h1, h2 { line-height: 1.2; }
    .card { margin: 18px 0; padding: 18px; border: 1px solid #dce2ea; border-radius: 14px; }
    .button { display: inline-block; margin: 6px 8px 6px 0; padding: 11px 15px; color: white; background: #1769e0; border-radius: 9px; text-decoration: none; }
    .warning { color: #7b3d00; background: #fff4de; }
    img { max-width: 280px; width: 100%; }
    code { overflow-wrap: anywhere; }
  </style>
</head>
<body>
  <h1>VPNICA готова</h1>
  <p>Выберите нужный вариант подключения.</p>

  <div class="card">
    <h2>OpenVPN</h2>
    <p><strong>Весь трафик через VPN</strong></p>
    <a class="button" href="family.ovpn" download>Скачать family.ovpn</a>

    <p><strong>Только адреса из списка через VPN</strong></p>
    <a class="button" href="family-split-exact.ovpn" download>Скачать split-профиль</a>

    <p><strong>Россия напрямую, остальное через VPN</strong></p>
    <a class="button" href="family-russia-direct.ovpn" download>Скачать Russia Direct</a>

    <p>Импортируйте выбранный файл в OpenVPN Connect или в настройках VPN вашего роутера.</p>
  </div>

  <div class="card">
    <h2>Telegram-прокси Telemt</h2>
    <p><a class="button" href="$TELEMT_LINK_HTML">Подключить в Telegram</a></p>
    <p><img src="telemt-qr.png" alt="QR-код Telemt"></p>
  </div>

  <div class="card warning">
    <strong>Не публикуйте этот комплект.</strong>
    В профилях находятся действующие ключи доступа к вашему серверу.
  </div>
</body>
</html>
EOF

ARCHIVE="$SHARE_DIR/vpnica.zip"
(
  cd "$BUNDLE_DIR"
  zip -q -r "$ARCHIVE" .
)
chmod 600 "$ARCHIVE"

port_is_free() {
  local port="$1"
  ! ss -H -ltn "sport = :$port" | grep -q .
}

PORT=80
if ! port_is_free "$PORT"; then
  PORT=""
  for _ in $(seq 1 50); do
    CANDIDATE=$((20000 + RANDOM % 30000))
    if port_is_free "$CANDIDATE"; then
      PORT="$CANDIDATE"
      break
    fi
  done
fi
[[ -n "$PORT" ]] || vpnica_die "Не удалось найти свободный TCP-порт для временной ссылки."

TOKEN="$(openssl rand -hex 32)"
UNIT_NAME="vpnica-share-${TOKEN:0:12}"
UNIT="${UNIT_NAME}.service"

printf 'TOKEN=%s\nUNIT=%s\nPORT=%s\n' "$TOKEN" "$UNIT" "$PORT" > "$STATE_FILE"
chmod 600 "$STATE_FILE"

if ! systemd-run \
  --quiet \
  --unit "$UNIT_NAME" \
  --collect \
  --property=Type=exec \
  /usr/bin/python3 "$SCRIPT_DIR/share-server.py" \
    --archive "$ARCHIVE" \
    --token "$TOKEN" \
    --port "$PORT" \
    --ttl "$TTL_SECONDS" \
    --max-downloads "$MAX_DOWNLOADS" \
    --state-file "$STATE_FILE"; then
  rm -f -- "$ARCHIVE" "$STATE_FILE"
  vpnica_die "Не удалось запустить временный сервер скачивания."
fi

if [[ "$PORT" -eq 80 ]]; then
  DOWNLOAD_URL="http://${PUBLIC_HOST}/d/${TOKEN}/vpnica.zip"
else
  DOWNLOAD_URL="http://${PUBLIC_HOST}:${PORT}/d/${TOKEN}/vpnica.zip"
fi

echo
echo "Скачать готовый комплект в браузере:"
echo "$DOWNLOAD_URL"
echo
echo "Ссылка работает 30 минут и допускает до 3 успешных скачиваний."
echo "Это обычный HTTP: не передавайте ссылку посторонним."
echo "Создать новую ссылку: vpnica share"
echo
echo "Telegram-прокси:"
echo "$TELEMT_LINK"
