#!/usr/bin/env bash

set_top_level_string() {
  local config_file=${1:?config file required}
  local key=${2:?key required}
  local value=${3:?value required}
  local temp_file

  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    printf 'invalid config key: %s\n' "$key" >&2
    return 1
  }
  [[ "$value" != *$'\n'* && "$value" != *\"* && "$value" != *\\* ]] || {
    printf 'unsupported characters in config value for %s\n' "$key" >&2
    return 1
  }
  [[ -f "$config_file" ]] || install -m 600 /dev/null "$config_file"

  temp_file=$(mktemp)
  awk -v key="$key" -v value="$value" '
    BEGIN { in_top = 1; wrote = 0 }
    in_top && /^[[:space:]]*\[/ {
      if (!wrote) {
        print key " = \"" value "\""
        wrote = 1
      }
      in_top = 0
    }
    in_top && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (!wrote) {
        print key " = \"" value "\""
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

remove_top_level_key() {
  local config_file=${1:?config file required}
  local key=${2:?key required}
  local temp_file

  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [[ -f "$config_file" ]] || return 0
  temp_file=$(mktemp)
  awk -v key="$key" '
    BEGIN { in_top = 1 }
    in_top && /^[[:space:]]*\[/ { in_top = 0 }
    in_top && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { next }
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

set_remote_defaults() {
  local config_file=${1:?config file required}
  local provider_id=${2:?provider id required}
  local model=${3:?model required}
  local reasoning=${4:?reasoning effort required}

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$reasoning" =~ ^(none|minimal|low|medium|high|xhigh)$ ]] || return 1
  set_top_level_string "$config_file" model_provider "$provider_id"
  set_top_level_string "$config_file" model "$model"
  set_top_level_string "$config_file" model_reasoning_effort "$reasoning"
}

restore_remote_defaults() {
  local config_file=${1:?config file required}
  local backup_file=${2:?backup file required}
  local key value

  for key in model_provider model model_reasoning_effort; do
    value=$(python3 - "$backup_file" "$key" <<'PY'
import pathlib, sys, tomllib
path = pathlib.Path(sys.argv[1])
data = tomllib.loads(path.read_text()) if path.is_file() else {}
value = data.get(sys.argv[2])
if isinstance(value, str):
    print(value)
PY
)
    if [[ -n "$value" ]]; then
      set_top_level_string "$config_file" "$key" "$value"
    else
      remove_top_level_key "$config_file" "$key"
    fi
  done
}

set_default_provider() {
  set_top_level_string "${1:?config file required}" model_provider "${2:?provider id required}"
}

remove_default_provider() {
  remove_top_level_key "${1:?config file required}" model_provider
}
