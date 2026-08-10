#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

((EUID == 0)) || { printf '请以 root 身份运行\n' >&2; exit 1; }
key_only='no'
[[ ${1-} == '--key-only' ]] && { key_only='yes'; shift; }
(($# == 0)) || { printf '错误：未知参数\n' >&2; exit 2; }

state_file=${CODEX_RP_STATE_FILE:-/var/lib/codex-remote-provider/state.env}
secret_file=${CODEX_RP_SECRET_FILE:-/etc/codex-remote-provider/provider.env}
[[ -r "$state_file" ]] || { printf '缺少安装状态，请先完成安装\n' >&2; exit 1; }
[[ -r "$secret_file" ]] || { printf '缺少第三方密钥文件\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"

base_url=$BASE_URL
model=$MODEL
reasoning=$REASONING
new_key=''
input=''

if [[ "$key_only" == no ]]; then
  printf '接口地址（Base URL）[%s]：' "$base_url"
  read -r input
  base_url=${input:-$base_url}
  printf '模型 [%s]：' "$model"
  read -r input
  model=${input:-$model}
  printf '推理强度 none/minimal/low/medium/high/xhigh [%s]：' "$reasoning"
  read -r input
  reasoning=${input:-$reasoning}
  printf '新 API Key（直接回车保留现有密钥）：'
else
  printf '请输入新的第三方 API Key：'
fi
read -rsp '' new_key
printf '\n'
if [[ -n "$new_key" ]]; then
  printf '已收到 API Key（%d 个字符，内容已隐藏）。\n' "${#new_key}"
  is_supported_api_key "$new_key" || {
    printf '错误：API Key 包含不支持的字符；请只复制密钥本身\n' >&2
    exit 1
  }
elif [[ "$key_only" == yes ]]; then
  printf '错误：新 API Key 不能为空\n' >&2
  exit 1
fi

if [[ "$key_only" == no ]]; then
  [[ "$base_url" =~ ^https://[^[:space:]]+$ ]] \
    || { printf '错误：Base URL 必须是无空格的 HTTPS 地址\n' >&2; exit 1; }
  [[ "$base_url" != *'@'* && "$base_url" != *'?'* && "$base_url" != *'#'* \
      && "$base_url" != *\"* && "$base_url" != *\\* ]] \
    || { printf '错误：Base URL 包含不支持的字符\n' >&2; exit 1; }
  [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || { printf '错误：模型名称无效\n' >&2; exit 1; }
  [[ "$reasoning" =~ ^(none|minimal|low|medium|high|xhigh)$ ]] \
    || { printf '错误：推理强度无效\n' >&2; exit 1; }
fi

work_dir=$(mktemp -d)
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT
cp -p "$secret_file" "$work_dir/secret"
cp -p "$state_file" "$work_dir/state"

config_file="$CODEX_HOME_DIR/config.toml"
profile_file="$CODEX_HOME_DIR/$PROVIDER_ID.config.toml"
third_party_unit_file=${THIRD_PARTY_UNIT_FILE:-/etc/systemd/system/codex-remote-provider.service}
[[ -f "$config_file" ]] && cp -p "$config_file" "$work_dir/config"
[[ -f "$profile_file" ]] && cp -p "$profile_file" "$work_dir/profile"
[[ -f "$third_party_unit_file" ]] && cp -p "$third_party_unit_file" "$work_dir/unit"

restore_on_error() {
  local exit_status=$?
  trap - ERR
  set +e
  install -m 600 "$work_dir/secret" "$secret_file"
  install -m 600 "$work_dir/state" "$state_file"
  [[ -f "$work_dir/config" ]] && install -m 600 "$work_dir/config" "$config_file"
  [[ -f "$work_dir/profile" ]] && install -m 600 "$work_dir/profile" "$profile_file"
  [[ -f "$work_dir/unit" ]] && install -m 644 "$work_dir/unit" "$third_party_unit_file"
  systemctl daemon-reload >/dev/null 2>&1
  printf '更新失败；已恢复修改前的配置和密钥。\n' >&2
  exit "$exit_status"
}
trap restore_on_error ERR

if [[ -n "$new_key" ]]; then
  tmp_secret="$work_dir/new-secret"
  write_secret_environment_file "$tmp_secret" "$ENV_NAME" "$new_key"
  install -m 600 "$tmp_secret" "$secret_file"
fi

if [[ "$key_only" == no ]]; then
  tmp_config="$work_dir/new-config"
  begin_marker="# BEGIN codex-remote-provider-kit:$PROVIDER_ID"
  end_marker="# END codex-remote-provider-kit:$PROVIDER_ID"
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$config_file" > "$tmp_config"
  set_remote_defaults "$tmp_config" "$PROVIDER_ID" "$model" "$reasoning"
  cat >> "$tmp_config" <<EOF

$begin_marker
[model_providers.$PROVIDER_ID]
name = "$PROVIDER_ID"
base_url = "${base_url%/}"
env_key = "$ENV_NAME"
wire_api = "responses"
$end_marker
EOF
  python3 - "$tmp_config" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY
  install -m 600 "$tmp_config" "$config_file"
  printf 'model = "%s"\nmodel_provider = "%s"\nmodel_reasoning_effort = "%s"\n' \
    "$model" "$PROVIDER_ID" "$reasoning" > "$work_dir/new-profile"
  install -m 600 "$work_dir/new-profile" "$profile_file"
  set_state_variable "$state_file" BASE_URL "${base_url%/}"
  set_state_variable "$state_file" MODEL "$model"
  set_state_variable "$state_file" REASONING "$reasoning"
fi

# Reload generated units from the updated state without changing the selected mode.
CODEX_RP_STATE_FILE="$state_file" CODEX_RP_SECRET_FILE="$secret_file" \
  "$script_dir/refresh-units.sh"
third_party_unit_name=${third_party_unit_file##*/}
if systemctl is-active "$third_party_unit_name" >/dev/null 2>&1; then
  systemctl restart "$third_party_unit_name"
  "$script_dir/status.sh" --full
else
  printf '配置已更新；当前处于官方模式，切回第三方时生效。\n'
fi
trap - ERR
printf '第三方供应商配置更新完成。\n'
