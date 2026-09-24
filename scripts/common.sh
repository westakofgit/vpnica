#!/usr/bin/env bash

vpnica_die() {
  echo "$*" >&2
  exit 1
}

vpnica_require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    vpnica_die "Запустите команду от root."
  fi
}

vpnica_validate_host() {
  local host="${1,,}"
  local octet
  local label

  [[ -n "$host" && ${#host} -le 253 ]] || return 1

  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IFS='.' read -r -a octets <<< "$host"
    for octet in "${octets[@]}"; do
      [[ "$octet" =~ ^[0-9]+$ && "$octet" -le 255 ]] || return 1
    done
    printf '%s\n' "$host"
    return 0
  fi

  [[ "$host" == *.* && "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
  IFS='.' read -r -a labels <<< "$host"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
  printf '%s\n' "$host"
}

vpnica_set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local temporary

  temporary="$(mktemp "${file}.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    BEGIN { replaced = 0 }
    index($0, key "=") == 1 {
      if (!replaced) {
        print key "=" value
        replaced = 1
      }
      next
    }
    { print }
    END {
      if (!replaced) print key "=" value
    }
  ' "$file" > "$temporary"
  chmod --reference="$file" "$temporary" 2>/dev/null || chmod 600 "$temporary"
  mv "$temporary" "$file"
}
