#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

((EUID == 0)) || { printf '请以 root 身份运行\n' >&2; exit 1; }
state_file=${CODEX_RP_STATE_FILE:-/var/lib/codex-remote-provider/state.env}
is_root_only_regular_file "$state_file" \
  || { printf '状态文件缺失或类型无效；没有可安全回滚的内容\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"
third_party_unit_file=${THIRD_PARTY_UNIT_FILE:-/etc/systemd/system/codex-remote-provider.service}
official_unit_file=${OFFICIAL_UNIT_FILE:-/etc/systemd/system/codex-remote-official.service}
third_party_unit_name=${third_party_unit_file##*/}
official_unit_name=${official_unit_file##*/}
secret_file=${CODEX_RP_SECRET_FILE:-/etc/codex-remote-provider/provider.env}
resolve_provider_storage "$state_file" "$secret_file"
providers_dir=$CODEX_RP_PROVIDERS_PATH
provider_secrets_dir=$CODEX_RP_PROVIDER_SECRETS_PATH
installed_provider_id=${INSTALLED_PROVIDER_ID:-$PROVIDER_ID}
[[ ! -L "$providers_dir" && ( ! -e "$providers_dir" || -d "$providers_dir" ) ]] \
  || { printf '供应商记录目录类型无效；为避免误删，回滚已停止\n' >&2; exit 1; }
[[ ! -L "$provider_secrets_dir" \
    && ( ! -e "$provider_secrets_dir" || -d "$provider_secrets_dir" ) ]] \
  || { printf '供应商密钥目录类型无效；为避免误删，回滚已停止\n' >&2; exit 1; }
[[ ! -L "$secret_file" ]] \
  || { printf '活动密钥路径是符号链接；为避免误删，回滚已停止\n' >&2; exit 1; }
providers_dir_created='no'
provider_secrets_dir_created='no'
installed_profile_preexisted='no'
registry_cleanup_allowed='no'
if [[ -v OWNERSHIP_SCHEMA ]]; then
  [[ "$OWNERSHIP_SCHEMA" == 1 ]] \
    || { printf '不支持的所有权清单版本：%s\n' "$OWNERSHIP_SCHEMA" >&2; exit 1; }
  load_managed_provider_ids \
    || { printf '供应商所有权清单无效；为避免误删，回滚已停止\n' >&2; exit 1; }
  [[ "$installed_provider_id" =~ ^[A-Za-z0-9_-]+$ ]] \
    || { printf '初始 Provider ID 无效；回滚已停止\n' >&2; exit 1; }
  provider_is_managed "$PROVIDER_ID" \
    || { printf '当前 Provider 不在所有权清单中；回滚已停止\n' >&2; exit 1; }
  registry_cleanup_allowed='yes'
  profile_markers_required=$PROFILE_MARKERS_REQUIRED
  is_root_only_directory "$providers_dir" \
    && is_root_only_directory "$provider_secrets_dir" \
    || { printf '受管 Provider 目录权限或所有者无效；回滚已停止\n' >&2; exit 1; }
  providers_dir_created=${PROVIDERS_DIR_CREATED_BY_KIT:-}
  provider_secrets_dir_created=${PROVIDER_SECRETS_DIR_CREATED_BY_KIT:-}
  installed_profile_preexisted=${INSTALLED_PROFILE_PREEXISTED:-}
  [[ "$providers_dir_created" =~ ^(yes|no)$ \
      && "$provider_secrets_dir_created" =~ ^(yes|no)$ \
      && "$installed_profile_preexisted" =~ ^(yes|no)$ ]] \
    || { printf '所有权清单字段无效；为避免误删，回滚已停止\n' >&2; exit 1; }
else
  CODEX_RP_MANAGED_PROVIDER_IDS=()
  profile_markers_required='no'
  [[ -f "$BACKUP_DIR/profile.config.toml" ]] && installed_profile_preexisted='yes'
fi
if [[ "$installed_profile_preexisted" == yes \
    ]] && ! is_root_owned_regular_file "$BACKUP_DIR/profile.config.toml"; then
  printf '缺少安装前 profile 备份；为避免数据丢失，回滚已停止\n' >&2
  exit 1
fi

is_root_only_directory "$BACKUP_DIR" \
  || { printf '备份目录必须由 root 拥有、权限为 0700 且不能是符号链接；回滚已停止\n' >&2; exit 1; }
for backup_file in config.toml profile.config.toml \
    codex-remote-provider.service codex-remote-official.service codex-rp; do
  backup_path="$BACKUP_DIR/$backup_file"
  if [[ -e "$backup_path" || -L "$backup_path" ]]; then
    is_root_owned_regular_file "$backup_path" \
      || { printf '备份文件权限或类型无效：%s；回滚已停止\n' \
        "$backup_path" >&2; exit 1; }
  fi
done
[[ ${THIRD_PARTY_UNIT_EXISTED:-no} != yes \
    || -f "$BACKUP_DIR/codex-remote-provider.service" ]] \
  || { printf '缺少安装前第三方 unit 备份；回滚已停止\n' >&2; exit 1; }
[[ ${OFFICIAL_UNIT_EXISTED:-no} != yes \
    || -f "$BACKUP_DIR/codex-remote-official.service" ]] \
  || { printf '缺少安装前官方 unit 备份；回滚已停止\n' >&2; exit 1; }
[[ ${COMMAND_EXISTED:-no} != yes || -f "$BACKUP_DIR/codex-rp" ]] \
  || { printf '缺少安装前全局命令备份；回滚已停止\n' >&2; exit 1; }

if [[ "$registry_cleanup_allowed" == yes ]]; then
  installed_provider_managed='no'
  for managed_provider_id in "${CODEX_RP_MANAGED_PROVIDER_IDS[@]}"; do
    [[ "$managed_provider_id" != "$installed_provider_id" ]] \
      || installed_provider_managed='yes'
  done
  installed_profile="$CODEX_HOME_DIR/$installed_provider_id.config.toml"
  if [[ "$installed_provider_managed" == no \
      && ( -e "$installed_profile" || -L "$installed_profile" ) ]]; then
    printf '初始 Provider 已迁移，但其旧 profile 路径被其他文件占用；回滚已停止\n' >&2
    exit 1
  fi
fi

if [[ "$registry_cleanup_allowed" == yes ]]; then
  for managed_provider_id in "${CODEX_RP_MANAGED_PROVIDER_IDS[@]}"; do
    managed_provider_artifacts_match "$providers_dir" "$provider_secrets_dir" \
      "$CODEX_HOME_DIR" "$managed_provider_id" "$profile_markers_required" || {
      printf '受管 Provider 文件缺失、被替换或内容不匹配：%s；回滚已停止\n' \
        "$managed_provider_id" >&2
      exit 1
    }
  done
else
  legacy_profile="$CODEX_HOME_DIR/$installed_provider_id.config.toml"
  if [[ -e "$legacy_profile" || -L "$legacy_profile" ]]; then
    provider_profile_matches "$legacy_profile" "$installed_provider_id" \
      "$MODEL" "$REASONING" no || {
      printf '旧版 Provider profile 已被替换；回滚已停止\n' >&2
      exit 1
    }
  fi
fi

is_root_only_regular_file "$secret_file" \
  || { printf '活动密钥路径缺失、权限错误或类型无效；回滚已停止\n' >&2; exit 1; }
read_secret_environment_value "$secret_file" "$ENV_NAME" \
  || { printf '活动密钥文件内容无效；回滚已停止\n' >&2; exit 1; }
if [[ "$registry_cleanup_allowed" == yes ]]; then
  current_secret=$(provider_secret_path "$provider_secrets_dir" "$PROVIDER_ID")
  cmp -s "$secret_file" "$current_secret" \
    || { printf '活动密钥与当前受管 Provider 不匹配；回滚已停止\n' >&2; exit 1; }
fi

managed_path_is_safe() {
  local target_file=${1:?target file required}
  local marker=${2:?marker required}

  [[ ! -L "$target_file" ]] || return 1
  [[ -e "$target_file" ]] || return 0
  [[ -f "$target_file" ]] || return 1
  grep -Fxq "$marker" "$target_file"
}

managed_marker='# Managed by codex-remote-provider-kit'
command_file=${COMMAND_FILE:-/usr/local/bin/codex-rp}
paths_are_distinct "$providers_dir" "$provider_secrets_dir" "$BACKUP_DIR" \
  "$CODEX_HOME_DIR" \
  || { printf 'Provider、备份或 Codex 目录路径发生重叠；回滚已停止\n' >&2; exit 1; }
paths_are_distinct "$state_file" "$secret_file" "$CODEX_HOME_DIR/config.toml" \
  "$third_party_unit_file" "$official_unit_file" "$command_file" \
  "$BACKUP_DIR/codex-remote-official.service" \
  || { printf '状态、配置、unit、备份或命令路径发生重叠；回滚已停止\n' >&2; exit 1; }
managed_path_is_safe "$third_party_unit_file" "$managed_marker" \
  || { printf '第三方 unit 已被非受管文件替换；回滚已停止\n' >&2; exit 1; }
managed_path_is_safe "$official_unit_file" "$managed_marker" \
  || { printf '官方 unit 已被非受管文件替换；回滚已停止\n' >&2; exit 1; }
managed_path_is_safe "$command_file" "$managed_marker" \
  || { printf '全局命令已被非受管文件替换；回滚已停止\n' >&2; exit 1; }
live_config_file="$CODEX_HOME_DIR/config.toml"
if [[ -e "$live_config_file" || -L "$live_config_file" ]]; then
  [[ -f "$live_config_file" && ! -L "$live_config_file" ]] \
    || { printf '用户配置路径存在且不是普通文件；回滚已停止\n' >&2; exit 1; }
fi

printf '回滚将删除持久化的供应商密钥，并从 %s 恢复配置。\n' "$BACKUP_DIR"
printf '请输入 ROLLBACK 继续：'
read -r confirmation
[[ "$confirmation" == 'ROLLBACK' ]] || { printf '操作已取消\n'; exit 1; }

third_party_enabled='no'
third_party_active='no'
official_enabled='no'
official_active='no'
legacy_enabled_before='no'
legacy_active_before='no'
systemctl is-enabled "$third_party_unit_name" >/dev/null 2>&1 \
  && third_party_enabled='yes'
systemctl is-active "$third_party_unit_name" >/dev/null 2>&1 \
  && third_party_active='yes'
systemctl is-enabled "$official_unit_name" >/dev/null 2>&1 \
  && official_enabled='yes'
systemctl is-active "$official_unit_name" >/dev/null 2>&1 \
  && official_active='yes'
systemctl is-enabled codex.service >/dev/null 2>&1 \
  && legacy_enabled_before='yes'
systemctl is-active codex.service >/dev/null 2>&1 \
  && legacy_active_before='yes'

transaction_dir=$(mktemp -d)
chmod 700 "$transaction_dir"
transaction_committed='no'
preserve_transaction_dir='no'
audit_dir="$(dirname "$state_file")/audit"
audit_dir_existed='no'
audit_file=''
audit_file_created='no'
[[ -d "$audit_dir" ]] && audit_dir_existed='yes'
declare -a transaction_paths=()
declare -a transaction_snapshots=()
declare -a transaction_existed=()
declare -A transaction_seen=()

transaction_cleanup() {
  local exit_status=$?

  trap - EXIT
  if [[ "$preserve_transaction_dir" == yes ]]; then
    printf '回滚事务快照保留在 root-only 临时目录：%s\n' \
      "$transaction_dir" >&2
  else
    rm -rf -- "$transaction_dir"
  fi
  exit "$exit_status"
}
trap transaction_cleanup EXIT

snapshot_transaction_path() {
  local target_path=${1:?target path required}
  local canonical snapshot_path index

  canonical=$(realpath -m -- "$target_path") || return 1
  [[ -z ${transaction_seen[$canonical]:-} ]] || return 0
  transaction_seen[$canonical]=1
  index=${#transaction_paths[@]}
  snapshot_path="$transaction_dir/path-$index"
  transaction_paths+=("$target_path")
  transaction_snapshots+=("$snapshot_path")
  if [[ -e "$target_path" || -L "$target_path" ]]; then
    cp -a -- "$target_path" "$snapshot_path" || return 1
    transaction_existed+=(yes)
  else
    transaction_existed+=(no)
  fi
}

restore_transaction_files() {
  local index target_path snapshot_path parent_dir
  local recovery_failed='no'

  for ((index=${#transaction_paths[@]} - 1; index >= 0; index--)); do
    target_path=${transaction_paths[index]}
    snapshot_path=${transaction_snapshots[index]}
    if [[ ${transaction_existed[index]} == yes ]]; then
      parent_dir=$(dirname "$target_path")
      if [[ ! -d "$parent_dir" ]]; then
        install -d -m 700 "$parent_dir" \
          || { printf '自动恢复失败：无法重建目录 %s\n' "$parent_dir" >&2; recovery_failed='yes'; continue; }
      fi
      rm -f -- "$target_path" \
        || { printf '自动恢复失败：无法清理 %s\n' "$target_path" >&2; recovery_failed='yes'; continue; }
      cp -a -- "$snapshot_path" "$target_path" \
        || { printf '自动恢复失败：无法恢复 %s\n' "$target_path" >&2; recovery_failed='yes'; }
    else
      rm -f -- "$target_path" \
        || { printf '自动恢复失败：无法删除新增路径 %s\n' "$target_path" >&2; recovery_failed='yes'; }
    fi
  done
  if [[ "$audit_file_created" == yes && -n "$audit_file" ]]; then
    rm -f -- "$audit_file" \
      || { printf '自动恢复失败：无法删除新增审计文件\n' >&2; recovery_failed='yes'; }
  fi
  if [[ "$audit_dir_existed" == no ]]; then
    rmdir "$audit_dir" >/dev/null 2>&1 || true
  fi
  [[ "$recovery_failed" == no ]]
}

restore_operation_service_state() {
  local recovery_failed='no'

  systemctl daemon-reload >/dev/null 2>&1 \
    || { printf '自动恢复失败：systemd daemon-reload\n' >&2; recovery_failed='yes'; }
  restore_remote_service_selection "$CODEX_BIN_PATH" \
    "$third_party_unit_name" "$official_unit_name" \
    "$third_party_enabled" "$third_party_active" \
    "$official_enabled" "$official_active" || recovery_failed='yes'
  if [[ ${LEGACY_ENABLED:-no} == yes || ${LEGACY_ACTIVE:-no} == yes \
      || "$legacy_enabled_before" == yes || "$legacy_active_before" == yes ]]; then
    systemctl disable --now codex.service >/dev/null 2>&1 \
      || { printf '自动恢复失败：无法停用 codex.service\n' >&2; recovery_failed='yes'; }
    if [[ "$legacy_enabled_before" == yes ]]; then
      systemctl enable codex.service >/dev/null 2>&1 \
        || { printf '自动恢复失败：无法重新启用 codex.service\n' >&2; recovery_failed='yes'; }
    fi
    if [[ "$legacy_active_before" == yes ]]; then
      systemctl start codex.service >/dev/null 2>&1 \
        || { printf '自动恢复失败：无法重新启动 codex.service\n' >&2; recovery_failed='yes'; }
    fi
  fi
  [[ "$recovery_failed" == no ]]
}

handle_rollback_error() {
  local exit_status=$?
  local recovery_failed='no'

  trap - ERR
  set +e
  restore_transaction_files || recovery_failed='yes'
  restore_operation_service_state || recovery_failed='yes'
  if [[ "$recovery_failed" == yes ]]; then
    preserve_transaction_dir='yes'
    printf '回滚失败，且自动恢复不完整；请使用保留的事务快照人工检查。\n' >&2
  else
    printf '回滚失败；已恢复回滚前的文件和服务模式。\n' >&2
  fi
  exit "$exit_status"
}

snapshot_transaction_path "$state_file"
snapshot_transaction_path "$CODEX_HOME_DIR/config.toml"
snapshot_transaction_path "$secret_file"
snapshot_transaction_path "$third_party_unit_file"
snapshot_transaction_path "$official_unit_file"
snapshot_transaction_path "$command_file"
snapshot_transaction_path "$CODEX_HOME_DIR/$installed_provider_id.config.toml"
if [[ "$registry_cleanup_allowed" == yes ]]; then
  for managed_provider_id in "${CODEX_RP_MANAGED_PROVIDER_IDS[@]}"; do
    snapshot_transaction_path \
      "$(provider_record_path "$providers_dir" "$managed_provider_id")"
    snapshot_transaction_path \
      "$(provider_secret_path "$provider_secrets_dir" "$managed_provider_id")"
    snapshot_transaction_path "$CODEX_HOME_DIR/$managed_provider_id.config.toml"
  done
fi
trap handle_rollback_error ERR

stop_failed='no'
if [[ -e "$third_party_unit_file" || "$third_party_enabled" == yes \
    || "$third_party_active" == yes ]]; then
  systemctl disable --now "$third_party_unit_name" >/dev/null 2>&1 \
    || { printf '停止第三方 Remote service 失败\n' >&2; stop_failed='yes'; }
fi
if [[ -e "$official_unit_file" || "$official_enabled" == yes \
    || "$official_active" == yes ]]; then
  systemctl disable --now "$official_unit_name" >/dev/null 2>&1 \
    || { printf '停止官方 Remote service 失败\n' >&2; stop_failed='yes'; }
fi
"$CODEX_BIN_PATH" remote-control stop --json >/dev/null 2>&1 \
  || { printf '停止 Codex Remote daemon 失败\n' >&2; stop_failed='yes'; }
if [[ "$stop_failed" == yes ]]; then
  false
fi

if [[ -f "$BACKUP_DIR/config.toml" ]]; then
  install -m 600 "$BACKUP_DIR/config.toml" "$CODEX_HOME_DIR/config.toml"
else
  tmp_config=$(mktemp)
  awk '
    /^# BEGIN codex-remote-provider-kit:/ { skip=1; next }
    /^# END codex-remote-provider-kit:/ { skip=0; next }
    !skip { print }
  ' "$CODEX_HOME_DIR/config.toml" > "$tmp_config"
  install -m 600 "$tmp_config" "$CODEX_HOME_DIR/config.toml"
  rm -f "$tmp_config"
  remove_top_level_key "$CODEX_HOME_DIR/config.toml" model_provider
  remove_top_level_key "$CODEX_HOME_DIR/config.toml" model
  remove_top_level_key "$CODEX_HOME_DIR/config.toml" model_reasoning_effort
fi

if [[ "$registry_cleanup_allowed" == yes ]]; then
  for managed_provider_id in "${CODEX_RP_MANAGED_PROVIDER_IDS[@]}"; do
    managed_record=$(provider_record_path "$providers_dir" "$managed_provider_id")
    managed_secret=$(provider_secret_path "$provider_secrets_dir" "$managed_provider_id")
    rm -f "$managed_record" "$managed_secret"
    if [[ "$managed_provider_id" != "$installed_provider_id" ]]; then
      rm -f "$CODEX_HOME_DIR/$managed_provider_id.config.toml"
    fi
  done
fi
if [[ "$installed_profile_preexisted" == yes ]]; then
  install -m 600 "$BACKUP_DIR/profile.config.toml" \
    "$CODEX_HOME_DIR/$installed_provider_id.config.toml"
else
  rm -f "$CODEX_HOME_DIR/$installed_provider_id.config.toml"
fi

rm -f "$secret_file"
[[ "$providers_dir_created" == yes ]] \
  && rmdir "$providers_dir" >/dev/null 2>&1 || true
[[ "$provider_secrets_dir_created" == yes ]] \
  && rmdir "$provider_secrets_dir" >/dev/null 2>&1 || true

if [[ -f "$BACKUP_DIR/codex-remote-provider.service" ]]; then
  install -m 644 "$BACKUP_DIR/codex-remote-provider.service" "$third_party_unit_file"
else
  rm -f "$third_party_unit_file"
fi
if [[ -f "$BACKUP_DIR/codex-remote-official.service" ]]; then
  install -m 644 "$BACKUP_DIR/codex-remote-official.service" "$official_unit_file"
else
  rm -f "$official_unit_file"
fi

if [[ -f "$BACKUP_DIR/codex-rp" ]]; then
  install -m 755 "$BACKUP_DIR/codex-rp" "$command_file"
elif [[ -f "$command_file" ]] && grep -Fxq '# Managed by codex-remote-provider-kit' "$command_file"; then
  rm -f "$command_file"
fi
service_restore_failed='no'
systemctl daemon-reload \
  || { printf '回滚失败：systemd daemon-reload\n' >&2; service_restore_failed='yes'; }

third_party_unit_existed=${THIRD_PARTY_UNIT_EXISTED:-no}
official_unit_existed=${OFFICIAL_UNIT_EXISTED:-no}
[[ -f "$BACKUP_DIR/codex-remote-provider.service" ]] && third_party_unit_existed='yes'
[[ -f "$BACKUP_DIR/codex-remote-official.service" ]] && official_unit_existed='yes'

if [[ "$third_party_unit_existed" == yes ]]; then
  if [[ ${THIRD_PARTY_UNIT_ENABLED:-no} == yes ]]; then
    systemctl enable "$third_party_unit_name" \
      || { printf '回滚失败：无法恢复第三方 unit 的启用状态\n' >&2; service_restore_failed='yes'; }
  else
    systemctl disable "$third_party_unit_name" >/dev/null 2>&1 \
      || { printf '回滚失败：无法恢复第三方 unit 的禁用状态\n' >&2; service_restore_failed='yes'; }
  fi
  if [[ ${THIRD_PARTY_UNIT_ACTIVE:-no} == yes ]]; then
    systemctl start "$third_party_unit_name" \
      || { printf '回滚失败：无法恢复第三方 unit 的运行状态\n' >&2; service_restore_failed='yes'; }
  fi
fi
if [[ "$official_unit_existed" == yes ]]; then
  if [[ ${OFFICIAL_UNIT_ENABLED:-no} == yes ]]; then
    systemctl enable "$official_unit_name" \
      || { printf '回滚失败：无法恢复官方 unit 的启用状态\n' >&2; service_restore_failed='yes'; }
  else
    systemctl disable "$official_unit_name" >/dev/null 2>&1 \
      || { printf '回滚失败：无法恢复官方 unit 的禁用状态\n' >&2; service_restore_failed='yes'; }
  fi
  if [[ ${OFFICIAL_UNIT_ACTIVE:-no} == yes ]]; then
    systemctl start "$official_unit_name" \
      || { printf '回滚失败：无法恢复官方 unit 的运行状态\n' >&2; service_restore_failed='yes'; }
  fi
fi
if [[ ${LEGACY_ENABLED:-no} == yes ]]; then
  systemctl enable codex.service \
    || { printf '回滚失败：无法重新启用 codex.service\n' >&2; service_restore_failed='yes'; }
fi
if [[ ${LEGACY_ACTIVE:-no} == yes ]]; then
  systemctl start codex.service \
    || { printf '回滚失败：无法重新启动 codex.service\n' >&2; service_restore_failed='yes'; }
fi
if [[ "$service_restore_failed" == yes ]]; then
  false
fi

install -d -m 700 "$audit_dir"
audit_file="$audit_dir/state-$(date +%Y%m%d-%H%M%S)-$$.env"
mv "$state_file" "$audit_file"
audit_file_created='yes'
transaction_committed='yes'
trap - ERR
printf '回滚完成。审计用状态文件保留在 %s；现在可以重新安装。\n' "$audit_file"
