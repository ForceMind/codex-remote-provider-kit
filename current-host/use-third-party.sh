#!/usr/bin/env bash
set -euo pipefail

((EUID == 0)) || { printf '请以 root 身份运行\n' >&2; exit 1; }
script_dir=$(cd "$(dirname "$0")" && pwd)
target='/etc/systemd/system/codex.service.d/10-third-party.conf'
env_name='THIRD_PARTY_API_KEY'
# shellcheck source=../lib.sh
source "$script_dir/../lib.sh"

if ! systemctl show-environment | cut -d= -f1 | grep -Fxq "$env_name"; then
  read -rsp "请输入第三方 API 密钥（${env_name}）：" api_key
  printf '\n'
  [[ -n "$api_key" && "$api_key" =~ ^[A-Za-z0-9._~+/-]+$ ]] || {
    printf 'API 密钥为空或格式无效\n' >&2
    exit 1
  }
  systemctl set-environment "$env_name=$api_key"
  unset api_key
fi

set_remote_defaults /root/.codex/config.toml third_party gpt-5.6-sol high
systemctl stop codex.service >/dev/null 2>&1 || true
/root/.local/bin/codex remote-control stop --json >/dev/null 2>&1 || true
install -d -m 755 "$(dirname "$target")"
install -m 644 "$script_dir/third-party.conf" "$target"
systemctl daemon-reload
systemctl reset-failed codex.service
systemctl start codex.service
printf '已切换到第三方供应商，当前 systemd 状态：\n'
systemctl show codex.service -p ActiveState -p SubState -p Result --no-pager
