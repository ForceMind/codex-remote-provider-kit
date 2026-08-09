#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

((EUID == 0)) || { printf 'run as root\n' >&2; exit 1; }
state_file='/var/lib/codex-remote-provider/state.env'
[[ -r "$state_file" ]] || { printf 'state file missing\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"

set_remote_defaults "$CODEX_HOME_DIR/config.toml" "$PROVIDER_ID" "$MODEL" "$REASONING"
"$CODEX_BIN_PATH" remote-control stop --json >/dev/null 2>&1 || true
systemctl restart codex-remote-provider.service
systemctl show codex-remote-provider.service -p ActiveState -p SubState -p Result --no-pager
