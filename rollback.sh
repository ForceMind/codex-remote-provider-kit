#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

dry_run='no'
case $# in
  0) ;;
  1) [[ $1 == --dry-run ]] || { printf '错误：rollback 仅接受 --dry-run\n' >&2; exit 2; }; dry_run='yes' ;;
  *) printf '错误：rollback 仅接受 --dry-run\n' >&2; exit 2 ;;
esac

((EUID == 0)) || { printf '请以 root 身份运行\n' >&2; exit 1; }
state_file=${CODEX_RP_STATE_FILE:-/var/lib/codex-remote-provider/state.env}
[[ -r "$state_file" ]] || { printf '缺少状态文件；没有可回滚的内容\n' >&2; exit 1; }
read_codex_rp_state "$state_file" || exit 1
third_party_unit_file=${THIRD_PARTY_UNIT_FILE:-/etc/systemd/system/codex-remote-provider.service}
official_unit_file=${OFFICIAL_UNIT_FILE:-/etc/systemd/system/codex-remote-official.service}
third_party_unit_name=${third_party_unit_file##*/}
official_unit_name=${official_unit_file##*/}
secret_file=${CODEX_RP_SECRET_FILE:-/etc/codex-remote-provider/provider.env}
shell_rc_file=${SHELL_RC_FILE:-/root/.bashrc}
command_file=${COMMAND_FILE:-/usr/local/bin/codex-rp}
config_file="$CODEX_HOME_DIR/config.toml"
profile_file="$CODEX_HOME_DIR/$PROVIDER_ID.config.toml"

current_remote_config_mode "$config_file" "$BACKUP_DIR/config.toml" \
  "$PROVIDER_ID" "$MODEL" "$REASONING"
mode=$CODEX_RP_CONFIG_MODE
[[ "$mode" != external && "$mode" != inconsistent ]] || {
  printf '检测到外部或不一致的顶层配置；已拒绝回滚，避免覆盖其他工具。\n' >&2
  exit 1
}
managed_provider_block_matches "$config_file" "$PROVIDER_ID" "$BASE_URL" "$ENV_NAME" || {
  printf '受管 provider 区块缺失、被修改或存在同名冲突；已拒绝回滚。\n' >&2
  exit 1
}
managed_profile_matches "$profile_file" "$PROVIDER_ID" "$MODEL" "$REASONING" || {
  printf '专用 profile 已被修改；已拒绝回滚。\n' >&2
  exit 1
}
for unit_file in "$third_party_unit_file" "$official_unit_file"; do
  [[ -f "$unit_file" ]] && grep -Fxq '# Managed by codex-remote-provider-kit' "$unit_file" || {
    printf 'Remote unit 缺失或所有权不明确：%s\n' "$unit_file" >&2
    exit 1
  }
done
if [[ -e "$command_file" ]] && ! grep -Fxq '# Managed by codex-remote-provider-kit' "$command_file"; then
  printf '全局命令已被替换为非套件内容；已拒绝回滚：%s\n' "$command_file" >&2
  exit 1
fi

printf '完整撤销计划：\n'
printf '  - 只移除本工具的 provider 区块并恢复三项官方默认配置\n'
printf '  - 保留安装后新增的其他 provider 和无关用户配置\n'
printf '  - 恢复或移除本工具管理的 profile、systemd unit 与 codex-rp 入口\n'
printf '  - 删除持久化的第三方凭据\n'
printf '  - 保留 ChatGPT 登录、Remote 配对和 Codex sessions\n'
if [[ "$dry_run" == yes ]]; then
  printf '预演完成：未修改配置、服务、入口、凭据或状态文件。\n'
  exit 0
fi
printf '请输入 ROLLBACK 继续：'
read -r confirmation
[[ "$confirmation" == ROLLBACK ]] || { printf '操作已取消\n'; exit 1; }

if ! rm -f "$secret_file" || [[ -e "$secret_file" ]]; then
  printf '无法删除第三方凭据；未修改配置、服务、unit、入口或活动状态。请修复权限后重试。\n' >&2
  exit 1
fi

systemctl disable --now "$third_party_unit_name" >/dev/null 2>&1 || true
systemctl disable --now "$official_unit_name" >/dev/null 2>&1 || true
stop_remote_control_bounded "$CODEX_BIN_PATH"

remove_managed_provider_block "$config_file" "$PROVIDER_ID"
if [[ "$mode" == third-party ]]; then
  restore_remote_defaults "$config_file" "$BACKUP_DIR/config.toml"
fi

if [[ -f "$BACKUP_DIR/profile.config.toml" ]]; then
  install -m 600 "$BACKUP_DIR/profile.config.toml" "$profile_file"
else
  rm -f "$profile_file"
fi

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

# ~/.bashrc is a live file the user keeps editing, unlike the tool-owned
# codex-rp launcher above, so an unbacked-up file only has our block removed
# instead of being deleted outright.
if [[ -f "$BACKUP_DIR/bashrc" ]]; then
  install -m 644 "$BACKUP_DIR/bashrc" "$shell_rc_file"
else
  remove_codex_shell_wrapper_block "$shell_rc_file"
fi
systemctl daemon-reload

third_party_unit_existed=${THIRD_PARTY_UNIT_EXISTED:-no}
official_unit_existed=${OFFICIAL_UNIT_EXISTED:-no}
[[ -f "$BACKUP_DIR/codex-remote-provider.service" ]] && third_party_unit_existed='yes'
[[ -f "$BACKUP_DIR/codex-remote-official.service" ]] && official_unit_existed='yes'
if [[ "$third_party_unit_existed" == yes ]]; then
  if [[ ${THIRD_PARTY_UNIT_ENABLED:-no} == yes ]]; then systemctl enable "$third_party_unit_name"; else systemctl disable "$third_party_unit_name" >/dev/null 2>&1 || true; fi
  [[ ${THIRD_PARTY_UNIT_ACTIVE:-no} != yes ]] || systemctl start "$third_party_unit_name"
fi
if [[ "$official_unit_existed" == yes ]]; then
  if [[ ${OFFICIAL_UNIT_ENABLED:-no} == yes ]]; then systemctl enable "$official_unit_name"; else systemctl disable "$official_unit_name" >/dev/null 2>&1 || true; fi
  [[ ${OFFICIAL_UNIT_ACTIVE:-no} != yes ]] || systemctl start "$official_unit_name"
fi
[[ ${LEGACY_ENABLED:-no} != yes ]] || systemctl enable codex.service
[[ ${LEGACY_ACTIVE:-no} != yes ]] || systemctl start codex.service

audit_dir="$(dirname "$state_file")/audit"
install -d -m 700 "$audit_dir"
audit_file="$audit_dir/state-$(date +%Y%m%d-%H%M%S)-$$.env"
mv "$state_file" "$audit_file"
printf '回滚完成。外部配置、账号、Remote 配对和 sessions 均已保留。\n'
printf '审计用状态文件：%s；现在可以重新安装。\n' "$audit_file"
