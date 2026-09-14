#!/usr/bin/env bash

read_kit_version() {
  local kit_dir=${1:?kit directory required}
  local version_file="$kit_dir/VERSION"
  local version

  [[ -r "$version_file" ]] || return 1
  IFS= read -r version < "$version_file" || return 1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || return 1
  printf '%s\n' "$version"
}

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
  local first_line extra_line value prefix

  [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  IFS= read -r first_line < "$secret_file" || return 1
  [[ $(wc -l < "$secret_file") -eq 1 ]] || return 1

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

read_managed_state() {
  local state_file=${1:?state file required}
  shift
  local allowed_keys=" $* " parsed_file key value

  [[ -f "$state_file" && ! -L "$state_file" && -r "$state_file" ]] || {
    printf '状态文件不存在、不可读或不是普通文件：%s\n' "$state_file" >&2
    return 1
  }
  command -v python3 >/dev/null 2>&1 || {
    printf '读取状态需要 Python 3\n' >&2
    return 1
  }
  parsed_file=$(mktemp) || return 1
  if ! python3 - "$state_file" > "$parsed_file" <<'PY'
import pathlib
import re
import shlex
import sys

path = pathlib.Path(sys.argv[1])
for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
    match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(.*)", line)
    if not match:
        raise SystemExit(f"状态文件第 {number} 行语法无效")
    key, encoded = match.groups()
    try:
        words = shlex.split(f"value={encoded}", posix=True)
    except ValueError as error:
        raise SystemExit(f"状态文件第 {number} 行编码无效：{error}")
    if len(words) != 1 or not words[0].startswith("value="):
        raise SystemExit(f"状态文件第 {number} 行包含不受支持的语法")
    value = words[0][len("value="):]
    if "\n" in value or "\r" in value:
        raise SystemExit(f"状态文件第 {number} 行包含换行")
    escaped = value.replace("'", "'\\''")
    print(f"{key}='{escaped}'")
PY
  then
    rm -f "$parsed_file"
    printf '无法安全解析状态文件：%s\n' "$state_file" >&2
    return 1
  fi

  while IFS= read -r key; do
    key=${key%%=*}
    [[ "$allowed_keys" == *" $key "* ]] || {
      rm -f "$parsed_file"
      printf '状态文件包含未知字段：%s\n' "$key" >&2
      return 1
    }
  done < "$parsed_file"
  # parsed_file is generated locally from decoded scalar values and contains
  # only allowlisted, single-quoted assignments.
  # shellcheck disable=SC1090
  source "$parsed_file"
  rm -f "$parsed_file"
}

read_codex_rp_state() {
  read_managed_state "${1:?state file required}" \
    PROVIDER_ID ENV_NAME BASE_URL MODEL REASONING CODEX_HOME_DIR CODEX_BIN_PATH \
    COMMAND_FILE BACKUP_DIR THIRD_PARTY_UNIT_FILE OFFICIAL_UNIT_FILE \
    THIRD_PARTY_UNIT_EXISTED THIRD_PARTY_UNIT_ENABLED THIRD_PARTY_UNIT_ACTIVE \
    OFFICIAL_UNIT_EXISTED OFFICIAL_UNIT_ENABLED OFFICIAL_UNIT_ACTIVE \
    COMMAND_EXISTED SHELL_RC_FILE SHELL_RC_EXISTED LEGACY_ENABLED LEGACY_ACTIVE
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
    printf 'case "${1-}" in help|-h|--help|version|-V|--version|status|doctor|rollback|uninstall) exec "$setup_script" "$@" ;; esac\n'
    printf 'if [[ ${1-} == --no-update ]]; then shift; export CODEX_RP_SKIP_AUTO_UPDATE=1; fi\n'
    printf 'if [[ -x "$kit_dir/auto-update.sh" && ${CODEX_RP_SKIP_AUTO_UPDATE:-0} != 1 ]]; then "$kit_dir/auto-update.sh" || exit $?; fi\n'
    printf 'if (($#)); then exec "$setup_script" "$@"; fi\n'
    printf 'exec "$setup_script" menu\n'
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

write_codex_shell_wrapper_block() {
  local target_file=${1:?target file required}
  local codex_bin=${2:?Codex executable required}
  local secret_file=${3:?secret file required}
  local third_party_unit_name=${4:?third-party unit name required}
  local quoted_codex_bin quoted_secret_file quoted_unit_name

  printf -v quoted_codex_bin '%q' "$codex_bin"
  printf -v quoted_secret_file '%q' "$secret_file"
  printf -v quoted_unit_name '%q' "$third_party_unit_name"

  # Runs a real per-invocation check (not a cached env var) so switching modes
  # takes effect on the next `codex` call without needing to re-source this file.
  cat > "$target_file" <<EOF
# BEGIN codex-remote-provider-kit:shell-integration
# Managed by codex-remote-provider-kit
# 第三方 Remote 服务处于 active 状态时，本机直接运行 codex 会自动带上第三方密钥；
# 官方模式下与未安装本工具前行为一致。已打开的终端需重新 source 本文件才会生效。
codex() {
  local __codex_rp_bin=$quoted_codex_bin
  if systemctl is-active --quiet $quoted_unit_name >/dev/null 2>&1 \\
      && [[ -r $quoted_secret_file ]]; then
    ( set -a; . $quoted_secret_file; set +a; "\$__codex_rp_bin" "\$@" )
  else
    "\$__codex_rp_bin" "\$@"
  fi
}
# END codex-remote-provider-kit:shell-integration
EOF
}

render_codex_shell_wrapper_rc() {
  local source_rc_file=${1:?source rc file required}
  local target_file=${2:?target file required}
  local codex_bin=${3:?Codex executable required}
  local secret_file=${4:?secret file required}
  local third_party_unit_name=${5:?third-party unit name required}
  local begin_marker='# BEGIN codex-remote-provider-kit:shell-integration'
  local end_marker='# END codex-remote-provider-kit:shell-integration'
  local block_file

  if [[ -f "$source_rc_file" ]]; then
    awk -v begin="$begin_marker" -v end="$end_marker" '
      $0 == begin { skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$source_rc_file" > "$target_file"
  else
    : > "$target_file"
  fi
  # Collapse trailing blank lines left by a previously stripped block so
  # repeated installs/refreshes don't accumulate blank lines over time.
  if [[ -s "$target_file" ]]; then
    printf '%s\n' "$(cat "$target_file")" > "$target_file"
  fi

  block_file=$(mktemp)
  write_codex_shell_wrapper_block "$block_file" "$codex_bin" "$secret_file" "$third_party_unit_name"
  [[ -s "$target_file" ]] && printf '\n' >> "$target_file"
  cat "$block_file" >> "$target_file"
  rm -f "$block_file"
}

remove_codex_shell_wrapper_block() {
  local rc_file=${1:?shell rc file required}
  local begin_marker='# BEGIN codex-remote-provider-kit:shell-integration'
  local end_marker='# END codex-remote-provider-kit:shell-integration'
  local temp_file

  [[ -f "$rc_file" ]] || return 0
  temp_file=$(mktemp)
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$rc_file" > "$temp_file"
  install -m 644 "$temp_file" "$rc_file"
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
TimeoutStopSec=30s
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
TimeoutStopSec=30s
Restart=no

[Install]
WantedBy=multi-user.target
EOF
}

systemd_unit_is_healthy() {
  local unit_name=${1:?systemd unit required}
  local active_state result

  active_state=$(systemctl show "$unit_name" -p ActiveState --value --no-pager) \
    || return 1
  result=$(systemctl show "$unit_name" -p Result --value --no-pager) \
    || return 1
  [[ "$active_state" == active && "$result" == success ]]
}

require_active_systemd_unit() {
  local unit_name=${1:?systemd unit required}

  if systemd_unit_is_healthy "$unit_name"; then
    return 0
  fi

  printf '错误：%s 启动后未保持正常状态。\n' "$unit_name" >&2
  systemctl show "$unit_name" \
    -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus \
    --no-pager >&2 || true
  printf '请检查：journalctl -u %s -n 100 --no-pager\n' "$unit_name" >&2
  return 1
}

stop_remote_control_bounded() {
  local codex_bin=${1:?Codex executable required}

  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=5s 30s \
      "$codex_bin" remote-control stop --json >/dev/null 2>&1 || true
  else
    "$codex_bin" remote-control stop --json >/dev/null 2>&1 || true
  fi
}

start_remote_systemd_unit() {
  local codex_bin=${1:?Codex executable required}
  local unit_name=${2:?systemd unit required}

  if systemctl --quiet start "$unit_name" \
      && systemd_unit_is_healthy "$unit_name"; then
    return 0
  fi

  printf '检测到 Remote 启动异常；正在停止残留 daemon，并重试一次同一模式……\n' >&2
  stop_remote_control_bounded "$codex_bin"
  systemctl reset-failed "$unit_name" >/dev/null 2>&1 || true

  systemctl --quiet start "$unit_name" || {
    require_active_systemd_unit "$unit_name" || true
    return 1
  }
  require_active_systemd_unit "$unit_name"
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
  stop_remote_control_bounded "$codex_bin"

  if [[ "$third_party_enabled" == yes ]]; then
    systemctl enable "$third_party_unit" >/dev/null 2>&1 || true
  fi
  if [[ "$official_enabled" == yes ]]; then
    systemctl enable "$official_unit" >/dev/null 2>&1 || true
  fi
  if [[ "$third_party_active" == yes ]]; then
    start_remote_systemd_unit "$codex_bin" "$third_party_unit" \
      >/dev/null 2>&1 || true
  fi
  if [[ "$official_active" == yes ]]; then
    start_remote_systemd_unit "$codex_bin" "$official_unit" \
      >/dev/null 2>&1 || true
  fi
}

managed_provider_block_matches() {
  local config_file=${1:?config file required}
  local provider_id=${2:?provider id required}
  local base_url=${3:?base url required}
  local env_name=${4:?environment name required}

  python3 - "$config_file" "$provider_id" "$base_url" "$env_name" <<'PY'
import pathlib, re, sys
path, provider, base_url, env_name = pathlib.Path(sys.argv[1]), *sys.argv[2:]
if not path.is_file():
    raise SystemExit(1)
lines = path.read_text().splitlines()
begin = f"# BEGIN codex-remote-provider-kit:{provider}"
end = f"# END codex-remote-provider-kit:{provider}"
if lines.count(begin) != 1 or lines.count(end) != 1:
    raise SystemExit(1)
start, finish = lines.index(begin), lines.index(end)
if finish <= start:
    raise SystemExit(1)
actual = lines[start:finish + 1]
expected = [
    begin,
    f"[model_providers.{provider}]",
    f'name = "{provider}"',
    f'base_url = "{base_url}"',
    f'env_key = "{env_name}"',
    'wire_api = "responses"',
    end,
]
if actual != expected:
    raise SystemExit(1)
section = re.compile(r"^\s*\[model_providers\." + re.escape(provider) + r"\]\s*$")
if sum(bool(section.match(line)) for line in lines) != 1:
    raise SystemExit(1)
PY
}

managed_profile_matches() {
  local profile_file=${1:?profile file required}
  local provider_id=${2:?provider id required}
  local model=${3:?model required}
  local reasoning=${4:?reasoning effort required}
  [[ -f "$profile_file" ]] || return 1
  python3 - "$profile_file" "$provider_id" "$model" "$reasoning" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
expected = (
    f'model = "{sys.argv[3]}"\n'
    f'model_provider = "{sys.argv[2]}"\n'
    f'model_reasoning_effort = "{sys.argv[4]}"\n'
)
raise SystemExit(path.read_text() != expected)
PY
}

current_remote_config_mode() {
  local config_file=${1:?config file required}
  local backup_file=${2:?backup file required}
  local provider_id=${3:?provider id required}
  local model=${4:?model required}
  local reasoning=${5:?reasoning effort required}

  CODEX_RP_CONFIG_MODE=$(python3 - "$config_file" "$backup_file" \
    "$provider_id" "$model" "$reasoning" <<'PY'
import pathlib, sys, tomllib
config_path, backup_path = map(pathlib.Path, sys.argv[1:3])
try:
    config = tomllib.loads(config_path.read_text())
    original = tomllib.loads(backup_path.read_text()) if backup_path.is_file() else {}
except (OSError, tomllib.TOMLDecodeError):
    print("inconsistent")
    raise SystemExit
keys = ("model_provider", "model", "model_reasoning_effort")
managed = dict(zip(keys, sys.argv[3:6]))
if all(config.get(key) == value for key, value in managed.items()):
    print("third-party")
elif all(config.get(key) == original.get(key) for key in keys):
    print("official")
else:
    print("external")
PY
  ) || return 1
}

remove_managed_provider_block() {
  local config_file=${1:?config file required}
  local provider_id=${2:?provider id required}
  local temp_file begin_marker end_marker
  begin_marker="# BEGIN codex-remote-provider-kit:$provider_id"
  end_marker="# END codex-remote-provider-kit:$provider_id"
  temp_file=$(mktemp)
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$config_file" > "$temp_file"
  python3 - "$temp_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY
  install -m 600 "$temp_file" "$config_file"
  rm -f "$temp_file"
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
