#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

((EUID == 0)) || { printf '请以 root 身份运行\n' >&2; exit 1; }
state_file=${CODEX_RP_STATE_FILE:-/var/lib/codex-remote-provider/state.env}
is_root_only_regular_file "$state_file" \
  || { printf '状态文件缺失、权限错误或类型无效：%s\n' "$state_file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"
session_provider=$(session_provider_id) || {
  printf '错误：稳定会话供应商 ID 无效\n' >&2
  exit 1
}

third_party_unit_file=${THIRD_PARTY_UNIT_FILE:-/etc/systemd/system/codex-remote-provider.service}
official_unit_file=${OFFICIAL_UNIT_FILE:-/etc/systemd/system/codex-remote-official.service}
third_party_unit_name=${third_party_unit_file##*/}
official_unit_name=${official_unit_file##*/}
secret_file=${CODEX_RP_SECRET_FILE:-/etc/codex-remote-provider/provider.env}
command_file=${COMMAND_FILE:-/usr/local/bin/codex-rp}
command_marker='# Managed by codex-remote-provider-kit'
unit_marker='# Managed by codex-remote-provider-kit'

validate_command_target() {
  if [[ -L "$command_file" ]]; then
    printf '错误：%s 是符号链接，不能作为受管全局命令\n' "$command_file" >&2
    return 1
  fi
  if [[ ( -e "$command_file" || -L "$command_file" ) \
      && ! -f "$command_file" ]]; then
    printf '错误：%s 已存在，且不是可安全替换的普通文件\n' \
      "$command_file" >&2
    return 1
  fi
  if [[ -e "$command_file" || -L "$command_file" ]] \
      && ! grep -Fxq "$command_marker" "$command_file" 2>/dev/null; then
    printf '错误：%s 已存在，且不由本套件管理\n' "$command_file" >&2
    return 1
  fi
}

validate_command_target

remote_mode=$(remote_service_mode "$third_party_unit_name" "$official_unit_name") || {
  printf '错误：第三方和官方 Remote service 状态存在冲突\n' >&2
  exit 1
}
config_file=${CODEX_HOME_DIR:+$CODEX_HOME_DIR/config.toml}
official_unit_backup="$BACKUP_DIR/codex-remote-official.service"
[[ ! -L "$third_party_unit_file" && ! -L "$official_unit_file" \
    && ! -L "$official_unit_backup" && ! -L "$BACKUP_DIR" ]] \
  || { printf '错误：unit 或备份路径包含符号链接，无法安全刷新\n' >&2; exit 1; }
if [[ -e "$BACKUP_DIR" && ! -d "$BACKUP_DIR" ]]; then
  printf '错误：备份路径已存在且不是目录，无法安全刷新\n' >&2
  exit 1
fi
if [[ -e "$official_unit_backup" && ! -f "$official_unit_backup" ]]; then
  printf '错误：官方 unit 备份目标已存在且不是普通文件，无法安全刷新\n' >&2
  exit 1
fi
if [[ -n "$config_file" ]]; then
  [[ ! -L "$config_file" ]] \
    || { printf '错误：用户配置路径是符号链接，无法安全刷新\n' >&2; exit 1; }
  paths_are_distinct "$state_file" "$config_file" "$third_party_unit_file" \
    "$official_unit_file" "$command_file" "$official_unit_backup" \
    || { printf '错误：配置、unit、备份或命令路径发生重叠\n' >&2; exit 1; }
else
  paths_are_distinct "$state_file" "$third_party_unit_file" \
    "$official_unit_file" "$command_file" "$official_unit_backup" \
    || { printf '错误：状态、unit、备份或命令路径发生重叠\n' >&2; exit 1; }
fi
if [[ -e "$third_party_unit_file" ]] \
    && { [[ ! -f "$third_party_unit_file" ]] \
      || ! grep -Fxq "$unit_marker" "$third_party_unit_file"; }; then
  printf '错误：第三方 unit 已被非受管文件替换，无法安全刷新\n' >&2
  exit 1
fi
if [[ -e "$official_unit_file" && ! -f "$official_unit_file" ]]; then
  printf '错误：官方 unit 目标已存在且不是普通文件，无法安全刷新\n' >&2
  exit 1
fi
if [[ -f "$official_unit_file" && -f "$official_unit_backup" ]] \
    && ! grep -Fxq "$unit_marker" "$official_unit_file" \
    && ! cmp -s "$official_unit_file" "$official_unit_backup"; then
  printf '错误：官方 unit 与已有安装前备份均不匹配，无法安全刷新\n' >&2
  exit 1
fi

work_dir=$(mktemp -d)
transaction_committed='no'
transaction_snapshot_ready='no'
transaction_mutation_started='no'
preserve_work_dir='no'
state_existed='no'
config_existed='no'
backup_dir_existed='no'
backup_dir_mode=''
official_unit_backup_existed='no'
third_party_unit_existed='no'
official_unit_existed='no'
command_existed='no'

snapshot_path() {
  local source_path=${1:?source path required}
  local snapshot_name=${2:?snapshot name required}
  local result_variable=${3:?result variable required}

  if [[ -e "$source_path" || -L "$source_path" ]]; then
    cp -a -- "$source_path" "$work_dir/$snapshot_name"
    printf -v "$result_variable" '%s' yes
  else
    printf -v "$result_variable" '%s' no
  fi
}

restore_path() {
  local target_path=${1:?target path required}
  local snapshot_name=${2:?snapshot name required}
  local existed=${3:?existence state required}

  if [[ "$existed" == yes ]]; then
    rm -f -- "$target_path" || return 1
    cp -a -- "$work_dir/$snapshot_name" "$target_path"
  else
    rm -f -- "$target_path"
  fi
}

rollback_transaction() {
  local rollback_ok='yes'

  if ! restore_path "$command_file" command "$command_existed"; then
    rollback_ok='no'
  fi
  if ! restore_path "$official_unit_file" official-unit "$official_unit_existed"; then
    rollback_ok='no'
  fi
  if ! restore_path "$third_party_unit_file" third-party-unit \
      "$third_party_unit_existed"; then
    rollback_ok='no'
  fi
  if ! restore_path "$official_unit_backup" official-unit-backup \
      "$official_unit_backup_existed"; then
    rollback_ok='no'
  fi
  if [[ -n "$config_file" ]]; then
    if ! restore_path "$config_file" config "$config_existed"; then
      rollback_ok='no'
    fi
  fi
  if ! restore_path "$state_file" state "$state_existed"; then
    rollback_ok='no'
  fi

  if [[ "$backup_dir_existed" == yes ]]; then
    if ! chmod "$backup_dir_mode" "$BACKUP_DIR"; then
      rollback_ok='no'
    fi
  elif ! rmdir "$BACKUP_DIR" >/dev/null 2>&1 && [[ -d "$BACKUP_DIR" ]]; then
    rollback_ok='no'
  fi

  # Unit files may already have been observed by systemd, including when the
  # forward daemon-reload returned an error after doing partial work.
  if ! systemctl daemon-reload >/dev/null 2>&1; then
    rollback_ok='no'
  fi

  [[ "$rollback_ok" == yes ]]
}

cleanup() {
  local exit_status=$?
  local rollback_status=0

  trap - EXIT
  set +e
  if [[ "$transaction_committed" != yes \
      && "$transaction_snapshot_ready" == yes \
      && "$transaction_mutation_started" == yes ]]; then
    rollback_transaction
    rollback_status=$?
    if ((rollback_status == 0)); then
      printf '更新失败；已恢复修改前的配置、状态、备份和启动文件。\n' >&2
    else
      preserve_work_dir='yes'
      printf '更新失败，且至少一项回滚操作失败；请检查文件和 systemd 状态。\n' >&2
      printf '事务快照已保留在 root-only 临时目录：%s\n' "$work_dir" >&2
      ((exit_status != 0)) || exit_status=1
    fi
  fi
  if [[ "$preserve_work_dir" != yes ]]; then
    rm -rf -- "$work_dir"
  fi
  exit "$exit_status"
}
trap cleanup EXIT

snapshot_path "$state_file" state state_existed
if [[ -n "$config_file" ]]; then
  snapshot_path "$config_file" config config_existed
fi
if [[ -d "$BACKUP_DIR" ]]; then
  backup_dir_existed='yes'
  backup_dir_mode=$(stat -c '%a' -- "$BACKUP_DIR")
fi
snapshot_path "$official_unit_backup" official-unit-backup \
  official_unit_backup_existed
snapshot_path "$third_party_unit_file" third-party-unit third_party_unit_existed
snapshot_path "$official_unit_file" official-unit official_unit_existed
snapshot_path "$command_file" command command_existed
transaction_snapshot_ready='yes'

new_state_file="$work_dir/new-state"
new_config_file="$work_dir/new-config"
new_official_unit_backup="$work_dir/new-official-unit-backup"
tmp_third_party_unit="$work_dir/new-third-party-unit"
tmp_official_unit="$work_dir/new-official-unit"
tmp_command_file="$work_dir/new-command"
state_changed='no'
config_changed='no'
take_official_unit_backup='no'

cp -p -- "$work_dir/state" "$new_state_file"
if [[ -z ${SESSION_PROVIDER_ID:-} ]]; then
  set_state_variable "$new_state_file" SESSION_PROVIDER_ID "$session_provider"
  SESSION_PROVIDER_ID=$session_provider
  state_changed='yes'
fi

if [[ "$config_existed" == yes ]]; then
  cp -p -- "$work_dir/config" "$new_config_file"
  case "$remote_mode" in
    official)
      configure_official_session_provider "$new_config_file" "$session_provider"
      set_top_level_string "$new_config_file" model_provider "$session_provider"
      restore_official_model_defaults "$new_config_file" "$BACKUP_DIR/config.toml"
      config_changed='yes'
      ;;
    third-party)
      configure_third_party_session_provider "$new_config_file" "$session_provider" \
        "$BASE_URL" "$ENV_NAME"
      set_remote_defaults "$new_config_file" "$session_provider" "$MODEL" "$REASONING"
      config_changed='yes'
      ;;
  esac
  if [[ "$config_changed" == yes ]]; then
    python3 - "$new_config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY
  fi
fi

if [[ -f "$official_unit_file" ]] \
    && ! grep -Fxq "$unit_marker" "$official_unit_file" \
    && [[ ! -f "$official_unit_backup" ]]; then
  official_unit_enabled='no'
  official_unit_active='no'
  systemctl is-enabled "$official_unit_name" >/dev/null 2>&1 \
    && official_unit_enabled='yes'
  systemctl is-active "$official_unit_name" >/dev/null 2>&1 \
    && official_unit_active='yes'
  cp -p -- "$official_unit_file" "$new_official_unit_backup"
  set_state_variable "$new_state_file" OFFICIAL_UNIT_EXISTED yes
  set_state_variable "$new_state_file" OFFICIAL_UNIT_ENABLED "$official_unit_enabled"
  set_state_variable "$new_state_file" OFFICIAL_UNIT_ACTIVE "$official_unit_active"
  state_changed='yes'
  take_official_unit_backup='yes'
fi

write_third_party_unit "$tmp_third_party_unit" "$CODEX_BIN_PATH" "$secret_file" \
  "$session_provider" "$MODEL" "$REASONING"
write_official_unit "$tmp_official_unit" "$CODEX_BIN_PATH" "$session_provider"
write_command_launcher "$tmp_command_file" "$script_dir/setup.sh"

# Recheck after staging so a concurrently created non-managed command is not
# overwritten merely because the path passed the initial ownership check.
validate_command_target
transaction_mutation_started='yes'
install -d -m 700 "$BACKUP_DIR"
if [[ "$config_changed" == yes ]]; then
  install -m 600 "$new_config_file" "$config_file"
fi
if [[ "$state_changed" == yes ]]; then
  install -m 600 "$new_state_file" "$state_file"
fi
if [[ "$take_official_unit_backup" == yes ]]; then
  cp -p -- "$new_official_unit_backup" "$official_unit_backup"
fi
install -m 644 "$tmp_third_party_unit" "$third_party_unit_file"
install -m 644 "$tmp_official_unit" "$official_unit_file"
install -m 755 "$tmp_command_file" "$command_file"
systemctl daemon-reload
transaction_committed='yes'
printf 'Remote systemd unit 和全局命令已更新。\n'
