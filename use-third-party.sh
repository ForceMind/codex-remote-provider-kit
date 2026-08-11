#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

((EUID == 0)) || { printf '请以 root 身份运行\n' >&2; exit 1; }
(($# <= 1)) || { printf '错误：最多只能指定一个供应商 ID\n' >&2; exit 2; }
state_file=${CODEX_RP_STATE_FILE:-/var/lib/codex-remote-provider/state.env}
active_secret_file=${CODEX_RP_SECRET_FILE:-/etc/codex-remote-provider/provider.env}
is_root_only_regular_file "$state_file" \
  || { printf '状态文件缺失或类型无效\n' >&2; exit 1; }
is_root_only_regular_file "$active_secret_file" \
  || { printf '第三方密钥文件缺失或类型无效\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"
current_provider_id=$PROVIDER_ID
session_provider=$(session_provider_id) || {
  printf '错误：稳定会话供应商 ID 无效\n' >&2
  exit 1
}
resolve_provider_storage "$state_file" "$active_secret_file"
providers_dir=$CODEX_RP_PROVIDERS_PATH
provider_secrets_dir=$CODEX_RP_PROVIDER_SECRETS_PATH
current_record_file=$(provider_record_path "$providers_dir" "$current_provider_id")
current_stored_secret_file=$(provider_secret_path "$provider_secrets_dir" "$current_provider_id")
config_file="$CODEX_HOME_DIR/config.toml"
[[ ! -L "$providers_dir" && ( ! -e "$providers_dir" || -d "$providers_dir" ) ]] \
  || { printf '错误：供应商记录目录类型无效\n' >&2; exit 1; }
[[ ! -L "$provider_secrets_dir" \
    && ( ! -e "$provider_secrets_dir" || -d "$provider_secrets_dir" ) ]] \
  || { printf '错误：供应商密钥目录类型无效\n' >&2; exit 1; }
[[ ! -L "$current_record_file" && ! -L "$current_stored_secret_file" ]] \
  || { printf '错误：当前供应商注册文件包含符号链接，已拒绝切换\n' >&2; exit 1; }
[[ -f "$config_file" && ! -L "$config_file" ]] \
  || { printf '错误：用户配置缺失或类型无效\n' >&2; exit 1; }
paths_are_distinct "$state_file" "$active_secret_file" "$config_file" \
  "$current_record_file" "$current_stored_secret_file" \
  || { printf '错误：受管状态、配置或供应商路径发生重叠\n' >&2; exit 1; }
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
  || { printf '错误：unit、命令或备份路径包含符号链接，已拒绝切换\n' >&2; exit 1; }

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
transaction_snapshot_ready='yes'

if [[ -z ${SESSION_PROVIDER_ID:-} ]]; then
  set_state_variable "$state_file" SESSION_PROVIDER_ID "$session_provider"
  SESSION_PROVIDER_ID=$session_provider
fi
sync_current_provider_registry "$state_file" "$active_secret_file" || {
  printf '错误：当前第三方供应商状态或密钥文件无效\n' >&2
  exit 1
}

load_managed_provider_ids || { printf '错误：供应商所有权清单无效\n' >&2; exit 1; }
provider_records=()
for managed_provider_id in "${CODEX_RP_MANAGED_PROVIDER_IDS[@]}"; do
  managed_record=$(provider_record_path "$providers_dir" "$managed_provider_id")
  [[ -f "$managed_record" && ! -L "$managed_record" ]] \
    || { printf '错误：受管供应商记录缺失或类型无效：%s\n' "$managed_record" >&2; exit 1; }
  managed_provider_artifacts_match "$providers_dir" "$provider_secrets_dir" \
    "$CODEX_HOME_DIR" "$managed_provider_id" "$PROFILE_MARKERS_REQUIRED" \
    || { printf '错误：受管供应商文件缺失、被替换或内容不匹配：%s\n' \
      "$managed_provider_id" >&2; exit 1; }
  provider_records+=("$managed_record")
done
((${#provider_records[@]} > 0)) || { printf '没有已保存的第三方供应商\n' >&2; exit 1; }

selected_provider_id=${1-}
if [[ -z "$selected_provider_id" && -t 0 && ${#provider_records[@]} -gt 1 ]]; then
  printf '已保存的第三方供应商：\n'
  for ((index=0; index<${#provider_records[@]}; index++)); do
    record=${provider_records[index]}
    (
      load_provider_record "$record" || exit 1
      marker=''
      [[ "$PROVIDER_ID" == "$current_provider_id" ]] && marker='（当前）'
      printf '%d) %s%s\n   %s / %s / %s\n' \
        "$((index + 1))" "$PROVIDER_ID" "$marker" "$BASE_URL" "$MODEL" "$REASONING"
    )
  done
  printf '请选择 [1-%d]（直接回车保留当前）：' "${#provider_records[@]}"
  read -r selection
  if [[ -z "$selection" ]]; then
    selected_provider_id=$current_provider_id
  elif [[ "$selection" =~ ^[0-9]+$ ]] \
      && ((selection >= 1 && selection <= ${#provider_records[@]})); then
    selected_record=${provider_records[selection - 1]}
    selected_provider_id=${selected_record##*/}
    selected_provider_id=${selected_provider_id%.env}
  else
    printf '错误：无效的供应商序号\n' >&2
    exit 1
  fi
fi
selected_provider_id=${selected_provider_id:-$current_provider_id}
provider_is_managed "$selected_provider_id" \
  || { printf '错误：供应商不在受管清单中：%s\n' "$selected_provider_id" >&2; exit 1; }
record_file=$(provider_record_path "$providers_dir" "$selected_provider_id")
load_provider_record "$record_file" "$selected_provider_id" \
  || { printf '错误：供应商不存在或记录损坏：%s\n' "$selected_provider_id" >&2; exit 1; }
selected_secret_file=$(provider_secret_path "$provider_secrets_dir" "$PROVIDER_ID")
[[ -f "$selected_secret_file" && ! -L "$selected_secret_file" \
    && -r "$selected_secret_file" ]] \
  || { printf '错误：供应商 %s 尚未保存 API Key\n' "$PROVIDER_ID" >&2; exit 1; }
read_secret_environment_value "$selected_secret_file" "$ENV_NAME" \
  || { printf '错误：供应商 %s 的 API Key 文件无效\n' "$PROVIDER_ID" >&2; exit 1; }

selected_provider_id=$PROVIDER_ID
selected_env_name=$ENV_NAME
selected_base_url=$BASE_URL
selected_model=$MODEL
selected_reasoning=$REASONING
printf '切换前请确认当前 turn、工具调用和回复都已完整结束。\n'
cp -p "$active_secret_file" "$work_dir/active-secret"
cp -p "$config_file" "$work_dir/config"
[[ -f "$third_party_unit_file" ]] && cp -p "$third_party_unit_file" "$work_dir/third-party-unit"
[[ -f "$official_unit_file" ]] && cp -p "$official_unit_file" "$work_dir/official-unit"
[[ -f "$command_file" ]] && cp -p "$command_file" "$work_dir/command"
[[ -f "$official_unit_backup" ]] \
  && cp -p "$official_unit_backup" "$work_dir/official-unit-backup"

third_party_enabled='no'
third_party_active='no'
official_enabled='no'
official_active='no'
systemctl is-enabled "$third_party_unit_name" >/dev/null 2>&1 && third_party_enabled='yes'
systemctl is-active "$third_party_unit_name" >/dev/null 2>&1 && third_party_active='yes'
systemctl is-enabled "$official_unit_name" >/dev/null 2>&1 && official_enabled='yes'
systemctl is-active "$official_unit_name" >/dev/null 2>&1 && official_active='yes'

handle_switch_error() {
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
  transaction_committed='yes'
  if [[ "$recovery_failed" == yes ]]; then
    preserve_work_dir='yes'
    printf '切换失败，且自动恢复不完整；请使用保留的备份人工检查。\n' >&2
  else
    printf '切换失败；已恢复切换前配置和服务模式。\n' >&2
  fi
  exit "$exit_status"
}
trap handle_switch_error ERR

install -m 600 "$selected_secret_file" "$active_secret_file"
set_active_provider_state "$state_file" "$selected_provider_id" "$selected_env_name" \
  "$selected_base_url" "$selected_model" "$selected_reasoning"
set_state_variable "$state_file" PROVIDERS_DIR "$providers_dir"
set_state_variable "$state_file" PROVIDER_SECRETS_DIR "$provider_secrets_dir"
CODEX_RP_STATE_FILE="$state_file" CODEX_RP_SECRET_FILE="$active_secret_file" \
  "$script_dir/refresh-units.sh"
configure_third_party_session_provider "$config_file" "$session_provider" \
  "$selected_base_url" "$selected_env_name"
set_remote_defaults "$config_file" "$session_provider" "$selected_model" "$selected_reasoning"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY
systemctl --quiet disable --now "$official_unit_name"
"$CODEX_BIN_PATH" remote-control stop --json >/dev/null 2>&1 || true
systemctl --quiet enable "$third_party_unit_name"
systemctl restart "$third_party_unit_name"
printf '已切换到：%s\n%s / %s / %s\n' \
  "$selected_provider_id" "$selected_base_url" "$selected_model" "$selected_reasoning"
printf '稳定会话供应商：%s\n' "$session_provider"
printf '若原 thread 已使用该稳定 ID，重连后请先尝试继续；不可见时按文档显式恢复。\n'
printf '第三方 Remote 服务已重启，当前 systemd 状态：\n'
systemctl show "$third_party_unit_name" -p ActiveState -p SubState -p Result --no-pager
transaction_committed='yes'
trap - ERR
