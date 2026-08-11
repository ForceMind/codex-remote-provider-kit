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
active_secret_file=${CODEX_RP_SECRET_FILE:-/etc/codex-remote-provider/provider.env}
is_root_only_regular_file "$state_file" \
  || { printf '安装状态文件缺失或类型无效\n' >&2; exit 1; }
is_root_only_regular_file "$active_secret_file" \
  || { printf '第三方密钥文件缺失或类型无效\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"

current_provider_id=$PROVIDER_ID
current_env_name=$ENV_NAME
current_base_url=$BASE_URL
current_model=$MODEL
current_reasoning=$REASONING
session_provider=$(session_provider_id) || {
  printf '错误：稳定会话供应商 ID 无效\n' >&2
  exit 1
}
resolve_provider_storage "$state_file" "$active_secret_file"
providers_dir=$CODEX_RP_PROVIDERS_PATH
provider_secrets_dir=$CODEX_RP_PROVIDER_SECRETS_PATH
current_record_file=$(provider_record_path "$providers_dir" "$current_provider_id")
current_stored_secret_file=$(provider_secret_path "$provider_secrets_dir" "$current_provider_id")
current_profile_file="$CODEX_HOME_DIR/$current_provider_id.config.toml"
config_file="$CODEX_HOME_DIR/config.toml"
[[ ! -L "$providers_dir" && ( ! -e "$providers_dir" || -d "$providers_dir" ) ]] \
  || { printf '错误：供应商记录目录类型无效\n' >&2; exit 1; }
[[ ! -L "$provider_secrets_dir" \
    && ( ! -e "$provider_secrets_dir" || -d "$provider_secrets_dir" ) ]] \
  || { printf '错误：供应商密钥目录类型无效\n' >&2; exit 1; }
[[ ! -L "$current_record_file" && ! -L "$current_stored_secret_file" \
    && ! -L "$current_profile_file" ]] \
  || { printf '错误：当前供应商文件包含符号链接，已拒绝修改\n' >&2; exit 1; }
[[ -f "$config_file" && ! -L "$config_file" ]] \
  || { printf '错误：用户配置缺失或类型无效\n' >&2; exit 1; }
paths_are_distinct "$state_file" "$active_secret_file" "$config_file" \
  "$current_record_file" "$current_stored_secret_file" "$current_profile_file" \
  || { printf '错误：受管状态、配置或供应商路径发生重叠\n' >&2; exit 1; }
if [[ -v OWNERSHIP_SCHEMA ]]; then
  [[ "$OWNERSHIP_SCHEMA" == 1 ]] \
    || { printf '错误：供应商所有权清单版本无效\n' >&2; exit 1; }
  provider_is_managed "$current_provider_id" \
    && provider_profile_matches "$current_profile_file" "$current_provider_id" \
      "$current_model" "$current_reasoning" "$PROFILE_MARKERS_REQUIRED" \
    || { printf '错误：当前 Provider profile 与所有权清单不匹配\n' >&2; exit 1; }
fi

providers_dir_existed='no'
provider_secrets_dir_existed='no'
[[ -d "$providers_dir" ]] && providers_dir_existed='yes'
[[ -d "$provider_secrets_dir" ]] && provider_secrets_dir_existed='yes'
work_dir=$(mktemp -d)
transaction_committed='no'
transaction_snapshot_ready='no'
preserve_work_dir='no'
cleanup() {
  local exit_status=$?
  local recovery_failed='no'
  trap - EXIT
  set +e
  if [[ "$transaction_committed" != yes && "$transaction_snapshot_ready" == yes ]]; then
    install -m 600 "$work_dir/state" "$state_file" \
      || { printf '自动恢复失败：状态文件\n' >&2; recovery_failed='yes'; }
    if [[ ${CODEX_RP_REGISTRY_WRITE_STARTED:-no} == yes ]]; then
      if [[ -f "$work_dir/current-record" ]]; then
        install -m 600 "$work_dir/current-record" "$current_record_file" \
          || { printf '自动恢复失败：当前供应商记录\n' >&2; recovery_failed='yes'; }
      else
        rm -f "$current_record_file" \
          || { printf '自动恢复失败：删除新增供应商记录\n' >&2; recovery_failed='yes'; }
      fi
      if [[ -f "$work_dir/current-secret" ]]; then
        install -m 600 "$work_dir/current-secret" "$current_stored_secret_file" \
          || { printf '自动恢复失败：当前供应商密钥\n' >&2; recovery_failed='yes'; }
      else
        rm -f "$current_stored_secret_file" \
          || { printf '自动恢复失败：删除新增供应商密钥\n' >&2; recovery_failed='yes'; }
      fi
      [[ "$providers_dir_existed" == yes ]] \
        || rmdir "$providers_dir" >/dev/null 2>&1 || true
      [[ "$provider_secrets_dir_existed" == yes ]] \
        || rmdir "$provider_secrets_dir" >/dev/null 2>&1 || true
    fi
  fi
  if [[ "$recovery_failed" == yes ]]; then
    preserve_work_dir='yes'
    printf '自动恢复不完整；请使用保留的备份人工检查。\n' >&2
  fi
  if [[ "$preserve_work_dir" == yes ]]; then
    printf '自动恢复备份保留在 root-only 临时目录：%s\n' "$work_dir" >&2
  else
    rm -rf "$work_dir"
  fi
  exit "$exit_status"
}
trap cleanup EXIT
cp -p "$state_file" "$work_dir/state"
[[ -f "$current_record_file" ]] && cp -p "$current_record_file" "$work_dir/current-record"
[[ -f "$current_stored_secret_file" ]] \
  && cp -p "$current_stored_secret_file" "$work_dir/current-secret"
[[ -f "$current_profile_file" ]] && cp -p "$current_profile_file" "$work_dir/current-profile"
transaction_snapshot_ready='yes'

if [[ -z ${SESSION_PROVIDER_ID:-} ]]; then
  set_state_variable "$state_file" SESSION_PROVIDER_ID "$session_provider"
  SESSION_PROVIDER_ID=$session_provider
fi
sync_current_provider_registry "$state_file" "$active_secret_file" || {
  printf '错误：当前第三方供应商状态或密钥文件无效\n' >&2
  exit 1
}

third_party_unit_file=${THIRD_PARTY_UNIT_FILE:-/etc/systemd/system/codex-remote-provider.service}
official_unit_file=${OFFICIAL_UNIT_FILE:-/etc/systemd/system/codex-remote-official.service}
third_party_unit_name=${third_party_unit_file##*/}
official_unit_name=${official_unit_file##*/}
command_file=${COMMAND_FILE:-/usr/local/bin/codex-rp}
official_unit_backup="$BACKUP_DIR/codex-remote-official.service"
paths_are_distinct "$state_file" "$active_secret_file" "$config_file" \
  "$third_party_unit_file" "$official_unit_file" "$command_file" \
  "$official_unit_backup" \
  || { printf '错误：受管配置、unit、备份或命令路径发生重叠\n' >&2; exit 1; }
[[ ! -L "$third_party_unit_file" && ! -L "$official_unit_file" \
    && ! -L "$command_file" && ! -L "$official_unit_backup" ]] \
  || { printf '错误：unit、命令或备份路径包含符号链接，已拒绝更新\n' >&2; exit 1; }
remote_mode=$(remote_service_mode "$third_party_unit_name" "$official_unit_name") || {
  printf '错误：第三方和官方 Remote service 状态存在冲突\n' >&2
  exit 1
}
[[ "$remote_mode" != none ]] || {
  printf '错误：无法判断当前 Remote 模式；两个 service 均未启用或运行\n' >&2
  exit 1
}

third_party_enabled='no'
third_party_active='no'
official_enabled='no'
official_active='no'
systemctl is-enabled "$third_party_unit_name" >/dev/null 2>&1 && third_party_enabled='yes'
systemctl is-active "$third_party_unit_name" >/dev/null 2>&1 && third_party_active='yes'
systemctl is-enabled "$official_unit_name" >/dev/null 2>&1 && official_enabled='yes'
systemctl is-active "$official_unit_name" >/dev/null 2>&1 && official_active='yes'

base_url=$current_base_url
model=$current_model
reasoning=$current_reasoning
new_key=''
input=''

if [[ "$key_only" == no ]]; then
  printf '接口地址（Base URL）[%s]：' "$base_url"
  read -r input
  base_url=${input:-$base_url}
fi

[[ "$base_url" =~ ^https://[^[:space:]]+$ ]] \
  || { printf '错误：Base URL 必须是无空格的 HTTPS 地址\n' >&2; exit 1; }
[[ "$base_url" != *'@'* && "$base_url" != *'?'* && "$base_url" != *'#'* \
    && "$base_url" != *\"* && "$base_url" != *\\* ]] \
  || { printf '错误：Base URL 包含不支持的字符\n' >&2; exit 1; }
base_url=${base_url%/}
provider_id=$(provider_id_from_base_url "$base_url")
record_file=$(provider_record_path "$providers_dir" "$provider_id")
stored_secret_file=$(provider_secret_path "$provider_secrets_dir" "$provider_id")
profile_file="$CODEX_HOME_DIR/$provider_id.config.toml"
provider_exists='no'
if provider_is_managed "$provider_id"; then
  provider_exists='yes'
  [[ -f "$record_file" && ! -L "$record_file" ]] \
    || { printf '错误：受管供应商记录缺失或类型无效：%s\n' "$record_file" >&2; exit 1; }
  [[ -f "$stored_secret_file" && ! -L "$stored_secret_file" ]] \
    || { printf '错误：受管供应商密钥缺失或类型无效：%s\n' "$stored_secret_file" >&2; exit 1; }
  load_provider_record "$record_file" "$provider_id" \
    || { printf '错误：供应商记录损坏：%s\n' "$record_file" >&2; exit 1; }
  env_name=$ENV_NAME
  model=$MODEL
  reasoning=$REASONING
  provider_profile_matches "$profile_file" "$provider_id" "$model" "$reasoning" \
    "$PROFILE_MARKERS_REQUIRED" \
    || { printf '错误：受管 Provider profile 缺失或内容不匹配：%s\n' \
      "$profile_file" >&2; exit 1; }
else
  if [[ -e "$record_file" || -L "$record_file" \
      || -e "$stored_secret_file" || -L "$stored_secret_file" \
      || -e "$profile_file" || -L "$profile_file" ]]; then
    printf '错误：新 Provider ID 与非受管文件冲突：%s\n' "$provider_id" >&2
    exit 1
  fi
  env_name=$(provider_env_name_from_id "$provider_id")
fi

if [[ "$key_only" == no ]]; then
  printf '模型 [%s]：' "$model"
  read -r input
  model=${input:-$model}
  printf '推理强度 none/minimal/low/medium/high/xhigh [%s]：' "$reasoning"
  read -r input
  reasoning=${input:-$reasoning}
  if [[ "$provider_exists" == yes || "$base_url" == "${current_base_url%/}" ]]; then
    printf '新 API Key（直接回车保留该地址现有密钥）：'
  else
    printf '新地址的 API Key：'
  fi
else
  printf '请输入当前地址的新 API Key：'
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
elif [[ "$provider_exists" == no && "$base_url" != "${current_base_url%/}" ]]; then
  printf '错误：新增地址必须提供 API Key\n' >&2
  exit 1
fi

[[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || { printf '错误：模型名称无效\n' >&2; exit 1; }
[[ "$reasoning" =~ ^(none|minimal|low|medium|high|xhigh)$ ]] \
  || { printf '错误：推理强度无效\n' >&2; exit 1; }

cp -p "$active_secret_file" "$work_dir/active-secret"
cp -p "$config_file" "$work_dir/config"
[[ -f "$record_file" ]] && cp -p "$record_file" "$work_dir/target-record"
[[ -f "$stored_secret_file" ]] && cp -p "$stored_secret_file" "$work_dir/target-secret"
[[ -f "$profile_file" ]] && cp -p "$profile_file" "$work_dir/target-profile"
[[ -f "$third_party_unit_file" ]] && cp -p "$third_party_unit_file" "$work_dir/third-party-unit"
[[ -f "$official_unit_file" ]] && cp -p "$official_unit_file" "$work_dir/official-unit"
[[ -f "$command_file" ]] && cp -p "$command_file" "$work_dir/command"
[[ -f "$official_unit_backup" ]] \
  && cp -p "$official_unit_backup" "$work_dir/official-unit-backup"

restore_on_error() {
  local exit_status=$?
  local recovery_failed='no'
  trap - ERR
  set +e
  install -m 600 "$work_dir/state" "$state_file" \
    || { printf '自动恢复失败：状态文件\n' >&2; recovery_failed='yes'; }
  install -m 600 "$work_dir/active-secret" "$active_secret_file" \
    || { printf '自动恢复失败：活动密钥\n' >&2; recovery_failed='yes'; }
  install -m 600 "$work_dir/config" "$config_file" \
    || { printf '自动恢复失败：用户配置\n' >&2; recovery_failed='yes'; }
  if [[ -f "$work_dir/target-record" ]]; then
    install -m 600 "$work_dir/target-record" "$record_file" \
      || { printf '自动恢复失败：目标供应商记录\n' >&2; recovery_failed='yes'; }
  else
    rm -f "$record_file" \
      || { printf '自动恢复失败：删除新增供应商记录\n' >&2; recovery_failed='yes'; }
  fi
  if [[ -f "$work_dir/target-secret" ]]; then
    install -m 600 "$work_dir/target-secret" "$stored_secret_file" \
      || { printf '自动恢复失败：目标供应商密钥\n' >&2; recovery_failed='yes'; }
  else
    rm -f "$stored_secret_file" \
      || { printf '自动恢复失败：删除新增供应商密钥\n' >&2; recovery_failed='yes'; }
  fi
  if [[ -f "$work_dir/target-profile" ]]; then
    install -m 600 "$work_dir/target-profile" "$profile_file" \
      || { printf '自动恢复失败：目标 profile\n' >&2; recovery_failed='yes'; }
  else
    rm -f "$profile_file" \
      || { printf '自动恢复失败：删除新增 profile\n' >&2; recovery_failed='yes'; }
  fi
  if [[ -f "$work_dir/third-party-unit" ]]; then
    install -m 644 "$work_dir/third-party-unit" "$third_party_unit_file" \
      || { printf '自动恢复失败：第三方 unit\n' >&2; recovery_failed='yes'; }
  else
    rm -f "$third_party_unit_file" \
      || { printf '自动恢复失败：删除新增第三方 unit\n' >&2; recovery_failed='yes'; }
  fi
  if [[ -f "$work_dir/official-unit" ]]; then
    install -m 644 "$work_dir/official-unit" "$official_unit_file" \
      || { printf '自动恢复失败：官方 unit\n' >&2; recovery_failed='yes'; }
  else
    rm -f "$official_unit_file" \
      || { printf '自动恢复失败：删除新增官方 unit\n' >&2; recovery_failed='yes'; }
  fi
  if [[ -f "$work_dir/command" ]]; then
    install -m 755 "$work_dir/command" "$command_file" \
      || { printf '自动恢复失败：全局命令\n' >&2; recovery_failed='yes'; }
  elif [[ -f "$command_file" ]] \
      && grep -Fxq '# Managed by codex-remote-provider-kit' "$command_file"; then
    rm -f "$command_file" \
      || { printf '自动恢复失败：删除新增全局命令\n' >&2; recovery_failed='yes'; }
  fi
  if [[ -f "$work_dir/official-unit-backup" ]]; then
    install -m 644 "$work_dir/official-unit-backup" "$official_unit_backup" \
      || { printf '自动恢复失败：官方 unit 备份\n' >&2; recovery_failed='yes'; }
  else
    rm -f "$official_unit_backup" \
      || { printf '自动恢复失败：删除新增官方 unit 备份\n' >&2; recovery_failed='yes'; }
    rmdir "$BACKUP_DIR" >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload >/dev/null 2>&1 \
    || { printf '自动恢复失败：systemd daemon-reload\n' >&2; recovery_failed='yes'; }
  restore_remote_service_selection "$CODEX_BIN_PATH" \
    "$third_party_unit_name" "$official_unit_name" \
    "$third_party_enabled" "$third_party_active" \
    "$official_enabled" "$official_active" || recovery_failed='yes'
  if [[ ${CODEX_RP_REGISTRY_WRITE_STARTED:-no} == yes ]]; then
    if [[ -f "$work_dir/current-record" ]]; then
      install -m 600 "$work_dir/current-record" "$current_record_file" \
        || { printf '自动恢复失败：当前供应商记录\n' >&2; recovery_failed='yes'; }
    else
      rm -f "$current_record_file" \
        || { printf '自动恢复失败：删除新增供应商记录\n' >&2; recovery_failed='yes'; }
    fi
    if [[ -f "$work_dir/current-secret" ]]; then
      install -m 600 "$work_dir/current-secret" "$current_stored_secret_file" \
        || { printf '自动恢复失败：当前供应商密钥\n' >&2; recovery_failed='yes'; }
    else
      rm -f "$current_stored_secret_file" \
        || { printf '自动恢复失败：删除新增供应商密钥\n' >&2; recovery_failed='yes'; }
    fi
    [[ "$providers_dir_existed" == yes ]] \
      || rmdir "$providers_dir" >/dev/null 2>&1 || true
    [[ "$provider_secrets_dir_existed" == yes ]] \
      || rmdir "$provider_secrets_dir" >/dev/null 2>&1 || true
  fi
  if [[ ${migrate_legacy_id:-no} == yes ]]; then
    if [[ -f "$work_dir/current-profile" ]]; then
      install -m 600 "$work_dir/current-profile" "$current_profile_file" \
        || { printf '自动恢复失败：旧 Provider profile\n' >&2; recovery_failed='yes'; }
    fi
  fi
  transaction_committed='yes'
  if [[ "$recovery_failed" == yes ]]; then
    preserve_work_dir='yes'
    printf '更新失败，且自动恢复不完整；请使用保留的备份人工检查。\n' >&2
  else
    printf '更新失败；已恢复修改前的配置、密钥和服务模式。\n' >&2
  fi
  exit "$exit_status"
}
trap restore_on_error ERR

tmp_config="$work_dir/new-config"
begin_marker="# BEGIN codex-remote-provider-kit:$provider_id"
end_marker="# END codex-remote-provider-kit:$provider_id"
awk -v begin="$begin_marker" -v end="$end_marker" '
  $0 == begin { skip=1; next }
  $0 == end { skip=0; next }
  !skip { print }
' "$config_file" > "$tmp_config"

# Saving the same URL upgrades a legacy, manually named provider to the
# address-derived identity instead of leaving two entries for one endpoint.
migrate_legacy_id='no'
if [[ "$base_url" == "${current_base_url%/}" && "$provider_id" != "$current_provider_id" ]]; then
  migrate_legacy_id='yes'
  old_begin="# BEGIN codex-remote-provider-kit:$current_provider_id"
  old_end="# END codex-remote-provider-kit:$current_provider_id"
  awk -v begin="$old_begin" -v end="$old_end" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$tmp_config" > "$work_dir/without-legacy"
  mv "$work_dir/without-legacy" "$tmp_config"
fi

cat >> "$tmp_config" <<EOF

$begin_marker
[model_providers.$provider_id]
name = "$provider_id"
base_url = "$base_url"
env_key = "$env_name"
wire_api = "responses"
$end_marker
EOF
if [[ "$remote_mode" == third-party ]]; then
  configure_third_party_session_provider "$tmp_config" "$session_provider" \
    "$base_url" "$env_name"
  set_remote_defaults "$tmp_config" "$session_provider" "$model" "$reasoning"
else
  configure_official_session_provider "$tmp_config" "$session_provider"
  set_top_level_string "$tmp_config" model_provider "$session_provider"
  restore_official_model_defaults "$tmp_config" "$BACKUP_DIR/config.toml"
fi
python3 - "$tmp_config" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY

if [[ -n "$new_key" ]]; then
  write_secret_environment_file "$work_dir/new-secret" "$env_name" "$new_key"
elif [[ -r "$stored_secret_file" ]]; then
  cp -p "$stored_secret_file" "$work_dir/new-secret"
else
  read_secret_environment_value "$active_secret_file" "$current_env_name" \
    || { printf '错误：无法读取当前地址的密钥\n' >&2; exit 1; }
  write_secret_environment_file "$work_dir/new-secret" "$env_name" "$CODEX_RP_SECRET_VALUE"
fi

install -m 600 "$tmp_config" "$config_file"
printf '# Managed by codex-remote-provider-kit:%s\nmodel = "%s"\nmodel_provider = "%s"\nmodel_reasoning_effort = "%s"\n' \
  "$provider_id" "$model" "$provider_id" "$reasoning" > "$work_dir/new-profile"
install -m 600 "$work_dir/new-profile" "$profile_file"
write_provider_record "$record_file" "$provider_id" "$env_name" \
  "$base_url" "$model" "$reasoning"
install -m 600 "$work_dir/new-secret" "$stored_secret_file"
install -m 600 "$work_dir/new-secret" "$active_secret_file"
set_active_provider_state "$state_file" "$provider_id" "$env_name" \
  "$base_url" "$model" "$reasoning"
set_state_variable "$state_file" PROVIDERS_DIR "$providers_dir"
set_state_variable "$state_file" PROVIDER_SECRETS_DIR "$provider_secrets_dir"
set_state_variable "$state_file" SESSION_PROVIDER_ID "$session_provider"
if [[ "$provider_exists" == no ]]; then
  add_managed_provider_id "$state_file" "$provider_id"
fi
if [[ "$migrate_legacy_id" == yes ]]; then
  remove_managed_provider_id "$state_file" "$current_provider_id"
fi

CODEX_RP_STATE_FILE="$state_file" CODEX_RP_SECRET_FILE="$active_secret_file" \
  "$script_dir/refresh-units.sh"
if [[ "$third_party_active" == yes ]]; then
  systemctl restart "$third_party_unit_name"
  CODEX_RP_STATE_FILE="$state_file" CODEX_RP_SECRET_FILE="$active_secret_file" \
    "$script_dir/status.sh" --full
elif [[ "$remote_mode" == third-party ]]; then
  printf '配置已保存；第三方 Remote 当前已停止，下次启动时使用该地址。\n'
else
  printf '配置已保存；当前处于官方模式，切回第三方时使用该地址。\n'
fi

if [[ "$migrate_legacy_id" == yes ]]; then
  old_record=$(provider_record_path "$providers_dir" "$current_provider_id")
  old_secret=$(provider_secret_path "$provider_secrets_dir" "$current_provider_id")
  rm -f "$old_record" "$old_secret" "$CODEX_HOME_DIR/$current_provider_id.config.toml"
fi
transaction_committed='yes'
trap - ERR
printf '当前第三方配置：%s / %s / %s / %s\n' \
  "$provider_id" "$base_url" "$model" "$reasoning"
printf '第三方供应商配置已保存。\n'
