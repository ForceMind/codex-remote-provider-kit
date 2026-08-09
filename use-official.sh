#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

((EUID == 0)) || { printf '请以 root 身份运行\n' >&2; exit 1; }
state_file='/var/lib/codex-remote-provider/state.env'
[[ -r "$state_file" ]] || { printf '缺少状态文件\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"

printf '此操作将停止第三方供应商 Remote，并启动默认供应商。\n'
printf '可能会消耗官方额度。请输入 USE_OFFICIAL 继续：'
read -r confirmation
[[ "$confirmation" == 'USE_OFFICIAL' ]] || { printf '操作已取消\n'; exit 1; }

restore_remote_defaults "$CODEX_HOME_DIR/config.toml" "$BACKUP_DIR/config.toml"
systemctl stop codex-remote-provider.service || true
"$CODEX_BIN_PATH" remote-control stop --json >/dev/null 2>&1 || true
"$CODEX_BIN_PATH" remote-control start --json
printf 'Remote 已使用常规/默认 Codex 供应商启动。\n'
