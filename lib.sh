#!/usr/bin/env bash

set_default_provider() {
  local config_file=${1:?config file required}
  local provider_id=${2:?provider id required}
  local temp_file

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || {
    printf 'invalid provider id: %s\n' "$provider_id" >&2
    return 1
  }
  [[ -f "$config_file" ]] || install -m 600 /dev/null "$config_file"

  temp_file=$(mktemp)
  awk -v provider="$provider_id" '
    BEGIN { in_top = 1; wrote = 0 }
    in_top && /^[[:space:]]*\[/ {
      if (!wrote) {
        print "model_provider = \"" provider "\""
        wrote = 1
      }
      in_top = 0
    }
    in_top && /^[[:space:]]*model_provider[[:space:]]*=/ {
      if (!wrote) {
        print "model_provider = \"" provider "\""
        wrote = 1
      }
      next
    }
    { print }
    END {
      if (in_top && !wrote) print "model_provider = \"" provider "\""
    }
  ' "$config_file" > "$temp_file"

  if ! python3 - "$temp_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY
  then
    rm -f "$temp_file"
    return 1
  fi

  install -m 600 "$temp_file" "$config_file"
  rm -f "$temp_file"
}

remove_default_provider() {
  local config_file=${1:?config file required}
  local temp_file

  [[ -f "$config_file" ]] || return 0
  temp_file=$(mktemp)
  awk '
    BEGIN { in_top = 1 }
    in_top && /^[[:space:]]*\[/ { in_top = 0 }
    in_top && /^[[:space:]]*model_provider[[:space:]]*=/ { next }
    { print }
  ' "$config_file" > "$temp_file"

  if ! python3 - "$temp_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY
  then
    rm -f "$temp_file"
    return 1
  fi

  install -m 600 "$temp_file" "$config_file"
  rm -f "$temp_file"
}
