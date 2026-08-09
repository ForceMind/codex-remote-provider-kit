#!/usr/bin/env bash
set -euo pipefail

((EUID == 0)) || { printf 'run as root\n' >&2; exit 1; }
script_dir=$(cd "$(dirname "$0")" && pwd)
target='/etc/systemd/system/codex.service.d/10-inno-flare.conf'
env_name='INNO_FLARE_API_KEY'
# shellcheck source=../lib.sh
source "$script_dir/../lib.sh"

if ! systemctl show-environment | cut -d= -f1 | grep -Fxq "$env_name"; then
  read -rsp "$env_name: " api_key
  printf '\n'
  [[ -n "$api_key" && "$api_key" =~ ^[A-Za-z0-9._~+/-]+$ ]] || {
    printf 'invalid or empty API key\n' >&2
    exit 1
  }
  systemctl set-environment "$env_name=$api_key"
  unset api_key
fi

set_default_provider /root/.codex/config.toml inno_flare
systemctl stop codex.service >/dev/null 2>&1 || true
/root/.local/bin/codex remote-control stop --json >/dev/null 2>&1 || true
install -d -m 755 "$(dirname "$target")"
install -m 644 "$script_dir/third-party.conf" "$target"
systemctl daemon-reload
systemctl reset-failed codex.service
systemctl start codex.service
systemctl show codex.service -p ActiveState -p SubState -p Result --no-pager
