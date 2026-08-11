#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

((EUID == 0)) || { printf '请以 root 身份运行\n' >&2; exit 1; }
state_file=${CODEX_RP_STATE_FILE:-/var/lib/codex-remote-provider/state.env}
is_root_only_regular_file "$state_file" \
  || { printf '状态文件缺失或类型无效\n' >&2; exit 1; }
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

printf '此操作将停止第三方供应商 Remote，并启动默认供应商。\n'
printf '切换前请确认当前 turn、工具调用和回复都已完整结束。\n'
printf '可能会消耗官方额度。是否继续？[y/N]：'
read -r confirmation
case "$confirmation" in
  y|Y) ;;
  n|N|'') printf '操作已取消\n'; exit 0 ;;
  *) printf '请输入 y 或 n；操作已取消\n'; exit 1 ;;
esac

config_file="$CODEX_HOME_DIR/config.toml"
[[ -f "$config_file" && ! -L "$config_file" ]] \
  || { printf '错误：用户配置缺失或类型无效\n' >&2; exit 1; }
command_file=${COMMAND_FILE:-/usr/local/bin/codex-rp}
official_unit_backup="$BACKUP_DIR/codex-remote-official.service"
[[ ! -L "$third_party_unit_file" && ! -L "$official_unit_file" \
    && ! -L "$command_file" && ! -L "$official_unit_backup" ]] \
  || { printf '错误：unit、命令或备份路径包含符号链接，已拒绝切换\n' >&2; exit 1; }
paths_are_distinct "$state_file" "$config_file" "$third_party_unit_file" \
  "$official_unit_file" "$command_file" "$official_unit_backup" \
  || { printf '错误：受管配置、unit、备份或命令路径发生重叠\n' >&2; exit 1; }
work_dir=$(mktemp -d)
preserve_work_dir='no'
cleanup() {
  if [[ "$preserve_work_dir" == yes ]]; then
    printf '自动恢复备份保留在 root-only 临时目录：%s\n' "$work_dir" >&2
  else
    rm -rf "$work_dir"
  fi
}
trap cleanup EXIT
cp -p "$state_file" "$work_dir/state"
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
  if [[ "$recovery_failed" == yes ]]; then
    preserve_work_dir='yes'
    printf '切换失败，且自动恢复不完整；请使用保留的备份人工检查。\n' >&2
  else
    printf '切换失败；已恢复切换前配置和服务模式。\n' >&2
  fi
  exit "$exit_status"
}
trap handle_switch_error ERR

CODEX_RP_STATE_FILE="$state_file" "$script_dir/refresh-units.sh"
configure_official_session_provider "$config_file" "$session_provider"
set_top_level_string "$config_file" model_provider "$session_provider"
restore_official_model_defaults "$config_file" "$BACKUP_DIR/config.toml"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY
systemctl --quiet disable --now "$third_party_unit_name"
"$CODEX_BIN_PATH" remote-control stop --json >/dev/null 2>&1 || true
systemctl --quiet enable "$official_unit_name"
systemctl restart "$official_unit_name"
trap - ERR
printf 'Remote 已切换到官方推理；稳定会话供应商仍为 %s。\n' "$session_provider"
printf '若原 thread 已使用该稳定 ID，重连后请先尝试继续；不可见时按文档显式恢复。\n'
systemctl show "$official_unit_name" -p ActiveState -p SubState -p Result --no-pager
