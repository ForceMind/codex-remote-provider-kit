#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

((EUID == 0)) || { printf '请以 root 身份运行\n' >&2; exit 1; }
state_file=${CODEX_RP_STATE_FILE:-/var/lib/codex-remote-provider/state.env}
[[ -r "$state_file" ]] || { printf '缺少状态文件：%s\n' "$state_file" >&2; exit 1; }
read_codex_rp_state "$state_file" || exit 1

third_party_unit_file=${THIRD_PARTY_UNIT_FILE:-/etc/systemd/system/codex-remote-provider.service}
official_unit_file=${OFFICIAL_UNIT_FILE:-/etc/systemd/system/codex-remote-official.service}
secret_file=${CODEX_RP_SECRET_FILE:-/etc/codex-remote-provider/provider.env}
command_file=${COMMAND_FILE:-/usr/local/bin/codex-rp}
shell_rc_file=${SHELL_RC_FILE:-/root/.bashrc}
command_marker='# Managed by codex-remote-provider-kit'

if [[ -e "$command_file" ]] && ! grep -Fxq "$command_marker" "$command_file"; then
  printf '错误：%s 已存在，且不由本套件管理\n' "$command_file" >&2
  exit 1
fi

install -d -m 700 "$BACKUP_DIR"
if [[ -f "$official_unit_file" ]] \
    && ! grep -Fq '# Managed by codex-remote-provider-kit' "$official_unit_file" \
    && [[ ! -f "$BACKUP_DIR/codex-remote-official.service" ]]; then
  official_unit_enabled='no'
  official_unit_active='no'
  systemctl is-enabled "${official_unit_file##*/}" >/dev/null 2>&1 \
    && official_unit_enabled='yes'
  systemctl is-active "${official_unit_file##*/}" >/dev/null 2>&1 \
    && official_unit_active='yes'
  cp -p "$official_unit_file" "$BACKUP_DIR/codex-remote-official.service"
  {
    printf 'OFFICIAL_UNIT_EXISTED=%q\n' yes
    printf 'OFFICIAL_UNIT_ENABLED=%q\n' "$official_unit_enabled"
    printf 'OFFICIAL_UNIT_ACTIVE=%q\n' "$official_unit_active"
  } >> "$state_file"
  chmod 600 "$state_file"
fi

tmp_third_party_unit=$(mktemp)
tmp_official_unit=$(mktemp)
tmp_shell_rc=$(mktemp)
cleanup() { rm -f "$tmp_third_party_unit" "$tmp_official_unit" "$tmp_shell_rc"; }
trap cleanup EXIT

write_third_party_unit "$tmp_third_party_unit" "$CODEX_BIN_PATH" "$secret_file" \
  "$PROVIDER_ID" "$MODEL" "$REASONING"
write_official_unit "$tmp_official_unit" "$CODEX_BIN_PATH"
render_codex_shell_wrapper_rc "$shell_rc_file" "$tmp_shell_rc" "$CODEX_BIN_PATH" \
  "$secret_file" "${third_party_unit_file##*/}"

install -m 644 "$tmp_third_party_unit" "$third_party_unit_file"
install -m 644 "$tmp_official_unit" "$official_unit_file"
install_global_command "$script_dir/setup.sh" "$command_file"
install -m 644 "$tmp_shell_rc" "$shell_rc_file"
systemctl daemon-reload
printf 'Remote systemd unit、全局命令和本机 codex 快捷方式已更新。\n'
