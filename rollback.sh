#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

((EUID == 0)) || { printf '请以 root 身份运行\n' >&2; exit 1; }
state_file='/var/lib/codex-remote-provider/state.env'
[[ -r "$state_file" ]] || { printf '缺少状态文件；没有可回滚的内容\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"

printf '回滚将删除持久化的供应商密钥，并从 %s 恢复配置。\n' "$BACKUP_DIR"
printf '请输入 ROLLBACK 继续：'
read -r confirmation
[[ "$confirmation" == 'ROLLBACK' ]] || { printf '操作已取消\n'; exit 1; }

systemctl disable --now codex-remote-provider.service >/dev/null 2>&1 || true
"$CODEX_BIN_PATH" remote-control stop --json >/dev/null 2>&1 || true

if [[ -f "$BACKUP_DIR/config.toml" ]]; then
  install -m 600 "$BACKUP_DIR/config.toml" "$CODEX_HOME_DIR/config.toml"
else
  tmp_config=$(mktemp)
  awk -v begin="# BEGIN codex-remote-provider-kit:$PROVIDER_ID" \
      -v end="# END codex-remote-provider-kit:$PROVIDER_ID" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$CODEX_HOME_DIR/config.toml" > "$tmp_config"
  install -m 600 "$tmp_config" "$CODEX_HOME_DIR/config.toml"
  rm -f "$tmp_config"
  remove_top_level_key "$CODEX_HOME_DIR/config.toml" model_provider
  remove_top_level_key "$CODEX_HOME_DIR/config.toml" model
  remove_top_level_key "$CODEX_HOME_DIR/config.toml" model_reasoning_effort
fi

if [[ -f "$BACKUP_DIR/profile.config.toml" ]]; then
  install -m 600 "$BACKUP_DIR/profile.config.toml" "$CODEX_HOME_DIR/$PROVIDER_ID.config.toml"
else
  rm -f "$CODEX_HOME_DIR/$PROVIDER_ID.config.toml"
fi

rm -f /etc/codex-remote-provider/provider.env
rm -f /etc/systemd/system/codex-remote-provider.service
command_file=${COMMAND_FILE:-/usr/local/bin/codex-rp}
if [[ -f "$command_file" ]] && grep -Fxq '# Managed by codex-remote-provider-kit' "$command_file"; then
  rm -f "$command_file"
fi
systemctl daemon-reload

if [[ "$LEGACY_ENABLED" == yes ]]; then systemctl enable codex.service; fi
if [[ "$LEGACY_ACTIVE" == yes ]]; then systemctl start codex.service; fi
printf '回滚完成。审计用状态文件保留在 %s。\n' "$state_file"
