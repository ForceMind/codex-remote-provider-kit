#!/usr/bin/env bash
set -euo pipefail

((EUID == 0)) || { printf 'run as root\n' >&2; exit 1; }
script_dir=$(cd "$(dirname "$0")" && pwd)
target='/etc/systemd/system/codex.service.d/10-inno-flare.conf'
# shellcheck source=../lib.sh
source "$script_dir/../lib.sh"

printf 'This may consume official quota. Type USE_OFFICIAL to continue: '
read -r confirmation
[[ "$confirmation" == 'USE_OFFICIAL' ]] || { printf 'cancelled\n'; exit 1; }

set_default_provider /root/.codex/config.toml openai
remove_top_level_key /root/.codex/config.toml model
remove_top_level_key /root/.codex/config.toml model_reasoning_effort
systemctl stop codex.service >/dev/null 2>&1 || true
/root/.local/bin/codex remote-control stop --json >/dev/null 2>&1 || true
install -d -m 755 "$(dirname "$target")"
install -m 644 "$script_dir/official.conf" "$target"
systemctl daemon-reload
systemctl reset-failed codex.service
systemctl start codex.service
systemctl show codex.service -p ActiveState -p SubState -p Result --no-pager
