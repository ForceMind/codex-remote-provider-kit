#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

((EUID == 0)) || { printf '请以 root 身份运行\n' >&2; exit 1; }
state_file=${CODEX_RP_STATE_FILE:-/var/lib/codex-remote-provider/state.env}
[[ -r "$state_file" ]] || { printf '缺少状态文件\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"
third_party_unit_file=${THIRD_PARTY_UNIT_FILE:-/etc/systemd/system/codex-remote-provider.service}
official_unit_file=${OFFICIAL_UNIT_FILE:-/etc/systemd/system/codex-remote-official.service}
third_party_unit_name=${third_party_unit_file##*/}
official_unit_name=${official_unit_file##*/}

printf '此操作将停止第三方供应商 Remote，并启动默认供应商。\n'
printf '可能会消耗官方额度。请输入 USE_OFFICIAL 继续：'
read -r confirmation
[[ "$confirmation" == 'USE_OFFICIAL' ]] || { printf '操作已取消\n'; exit 1; }

CODEX_RP_STATE_FILE="$state_file" "$script_dir/refresh-units.sh"
config_file="$CODEX_HOME_DIR/config.toml"
original_config=$(mktemp)
cp -p "$config_file" "$original_config"
cleanup() { rm -f "$original_config"; }
trap cleanup EXIT

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
  trap - ERR
  set +e
  install -m 600 "$original_config" "$config_file"
  restore_remote_service_selection "$CODEX_BIN_PATH" \
    "$third_party_unit_name" "$official_unit_name" \
    "$third_party_enabled" "$third_party_active" \
    "$official_enabled" "$official_active"
  printf '切换失败；已尝试恢复切换前配置和服务模式。\n' >&2
  exit "$exit_status"
}
trap handle_switch_error ERR

restore_remote_defaults "$CODEX_HOME_DIR/config.toml" "$BACKUP_DIR/config.toml"
systemctl --quiet disable --now "$third_party_unit_name" >/dev/null 2>&1 || true
"$CODEX_BIN_PATH" remote-control stop --json >/dev/null 2>&1 || true
systemctl --quiet enable --now "$official_unit_name"
trap - ERR
printf 'Remote 已使用常规/默认 Codex 供应商启动，并将在重启后保持官方模式。\n'
systemctl show "$official_unit_name" -p ActiveState -p SubState -p Result --no-pager
