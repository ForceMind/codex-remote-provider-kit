#!/usr/bin/env bash

is_chatgpt_logged_in() {
  local codex_bin=${1:?Codex executable required}
  local login_status

  # Codex 0.147.0 writes the human-readable login status to stderr.
  login_status=$("$codex_bin" login status 2>&1) || return 1
  [[ "$login_status" == *'Logged in using ChatGPT'* ]]
}

is_supported_api_key() {
  local api_key=${1-}

  [[ -n "$api_key" ]] || return 1
  [[ "$api_key" != *$'\n'* && "$api_key" != *$'\r'* ]] || return 1
  # Accept common opaque, URL-safe, and padded Base64 token formats.
  [[ "$api_key" =~ ^[A-Za-z0-9._~+/=-]+$ ]]
}

write_command_launcher() {
  local target_file=${1:?target file required}
  local setup_script=${2:?setup script required}
  local marker='# Managed by codex-remote-provider-kit'

  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$marker"
    printf 'exec %q menu "$@"\n' "$setup_script"
  } > "$target_file"
  chmod 755 "$target_file"
}

install_global_command() {
  local setup_script=${1:?setup script required}
  local command_file=${2:-/usr/local/bin/codex-rp}
  local marker='# Managed by codex-remote-provider-kit'
  local temp_file

  if [[ -e "$command_file" ]] && ! grep -Fxq "$marker" "$command_file"; then
    printf 'error: %s already exists and is not managed by this kit\n' "$command_file" >&2
    return 1
  fi
  temp_file=$(mktemp)
  write_command_launcher "$temp_file" "$setup_script"
  install -m 755 "$temp_file" "$command_file"
  rm -f "$temp_file"
}

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
