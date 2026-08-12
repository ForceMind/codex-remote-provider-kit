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

write_secret_environment_file() {
  local target_file=${1:?target file required}
  local env_name=${2:?environment variable name required}
  local api_key=${3:?API key required}

  [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  is_supported_api_key "$api_key" || return 1
  # Double quotes keep values such as "~" literal when this file is sourced by
  # Bash during checks, and are also accepted by systemd EnvironmentFile=.
  printf '%s="%s"\n' "$env_name" "$api_key" > "$target_file"
  chmod 600 "$target_file"
}

read_secret_environment_value() {
  local secret_file=${1:?secret file required}
  local env_name=${2:?environment variable name required}
  local first_line extra_line value prefix secret_fd

  [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  exec {secret_fd}< "$secret_file" || return 1
  IFS= read -r first_line <&"$secret_fd" || {
    exec {secret_fd}<&-
    return 1
  }
  if IFS= read -r extra_line <&"$secret_fd"; then
    exec {secret_fd}<&-
    return 1
  fi
  exec {secret_fd}<&-

  prefix="$env_name="
  [[ "$first_line" == "$prefix"* ]] || return 1
  value=${first_line#"$prefix"}
  if [[ ${#value} -ge 2 && ${value:0:1} == '"' && ${value: -1} == '"' ]]; then
    value=${value:1:${#value}-2}
  elif [[ "$value" == *'"'* ]]; then
    return 1
  fi
  is_supported_api_key "$value" || return 1
  CODEX_RP_SECRET_VALUE=$value
}

write_command_launcher() {
  local target_file=${1:?target file required}
  local setup_script=${2:?setup script required}
  local kit_dir
  local marker='# Managed by codex-remote-provider-kit'

  kit_dir=$(cd -- "$(dirname -- "$setup_script")" && pwd -P)

  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$marker"
    printf 'kit_dir=%q\n' "$kit_dir"
    printf 'setup_script=%q\n' "$setup_script"
    printf 'if [[ -x "$kit_dir/auto-update.sh" ]]; then "$kit_dir/auto-update.sh" || exit $?; fi\n'
    printf 'exec "$setup_script" menu "$@"\n'
  } > "$target_file"
  chmod 755 "$target_file"
}

install_global_command() {
  local setup_script=${1:?setup script required}
  local command_file=${2:-/usr/local/bin/codex-rp}
  local marker='# Managed by codex-remote-provider-kit'
  local temp_file

  if [[ -e "$command_file" ]] && ! grep -Fxq "$marker" "$command_file"; then
    printf '错误：%s 已存在，且不由本套件管理\n' "$command_file" >&2
    return 1
  fi
  temp_file=$(mktemp)
  write_command_launcher "$temp_file" "$setup_script"
  install -m 755 "$temp_file" "$command_file"
  rm -f "$temp_file"
}

set_state_variable() {
  local state_file=${1:?state file required}
  local key=${2:?state key required}
  local value=${3-}
  local encoded temp_file

  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
  printf -v encoded '%q' "$value"
  temp_file=$(mktemp)
  awk -v key="$key" -v encoded="$encoded" '
    BEGIN { wrote=0 }
    $0 ~ "^" key "=" {
      if (!wrote) print key "=" encoded
      wrote=1
      next
    }
    { print }
    END { if (!wrote) print key "=" encoded }
  ' "$state_file" > "$temp_file"
  install -m 600 "$temp_file" "$state_file"
  rm -f "$temp_file"
}

write_third_party_unit() {
  local target_file=${1:?target file required}
  local codex_bin=${2:?Codex executable required}
  local secret_file=${3:?secret file required}
  local provider_id=${4:?provider id required}
  local model=${5:?model required}
  local reasoning=${6:?reasoning effort required}

  cat > "$target_file" <<EOF
# Managed by codex-remote-provider-kit
[Unit]
Description=使用第三方模型供应商的 Codex Remote
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
WorkingDirectory=/root
Environment=HOME=/root
EnvironmentFile=$secret_file
ExecStart=$codex_bin remote-control start --json -c model_provider=$provider_id -c model=$model -c model_reasoning_effort=$reasoning
ExecStop=$codex_bin remote-control stop --json
Restart=no

[Install]
WantedBy=multi-user.target
EOF
}

write_official_unit() {
  local target_file=${1:?target file required}
  local codex_bin=${2:?Codex executable required}

  cat > "$target_file" <<EOF
# Managed by codex-remote-provider-kit
[Unit]
Description=使用默认/官方模型供应商的 Codex Remote
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
WorkingDirectory=/root
Environment=HOME=/root
ExecStart=$codex_bin remote-control start --json
ExecStop=$codex_bin remote-control stop --json
Restart=no

[Install]
WantedBy=multi-user.target
EOF
}

require_active_systemd_unit() {
  local unit_name=${1:?systemd unit required}
  local active_state result

  active_state=$(systemctl show "$unit_name" -p ActiveState --value --no-pager) || {
    printf '错误：无法读取 %s 的 systemd 状态。\n' "$unit_name" >&2
    return 1
  }
  result=$(systemctl show "$unit_name" -p Result --value --no-pager) || {
    printf '错误：无法读取 %s 的 systemd 结果。\n' "$unit_name" >&2
    return 1
  }

  if [[ "$active_state" == active && "$result" == success ]]; then
    return 0
  fi

  printf '错误：%s 启动后未保持正常状态。\n' "$unit_name" >&2
  systemctl show "$unit_name" \
    -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus \
    --no-pager >&2 || true
  printf '请检查：journalctl -u %s -n 100 --no-pager\n' "$unit_name" >&2
  return 1
}

restore_remote_service_selection() {
  local codex_bin=${1:?Codex executable required}
  local third_party_unit=${2:?third-party unit required}
  local official_unit=${3:?official unit required}
  local third_party_enabled=${4:?third-party enabled state required}
  local third_party_active=${5:?third-party active state required}
  local official_enabled=${6:?official enabled state required}
  local official_active=${7:?official active state required}

  systemctl disable --now "$third_party_unit" >/dev/null 2>&1 || true
  systemctl disable --now "$official_unit" >/dev/null 2>&1 || true
  "$codex_bin" remote-control stop --json >/dev/null 2>&1 || true

  if [[ "$third_party_enabled" == yes ]]; then
    systemctl enable "$third_party_unit" >/dev/null 2>&1 || true
  fi
  if [[ "$official_enabled" == yes ]]; then
    systemctl enable "$official_unit" >/dev/null 2>&1 || true
  fi
  if [[ "$third_party_active" == yes ]]; then
    systemctl start "$third_party_unit" >/dev/null 2>&1 || true
  fi
  if [[ "$official_active" == yes ]]; then
    systemctl start "$official_unit" >/dev/null 2>&1 || true
  fi
}

set_top_level_string() {
  local config_file=${1:?config file required}
  local key=${2:?key required}
  local value=${3:?value required}
  local temp_file

  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    printf '配置键无效：%s\n' "$key" >&2
    return 1
  }
  [[ "$value" != *$'\n'* && "$value" != *\"* && "$value" != *\\* ]] || {
    printf '配置项 %s 的值包含不支持的字符\n' "$key" >&2
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
      if (in_top && !wrote) print key " = \"" value "\""
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
