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

printf 'This will stop custom-provider Remote and start the default provider.\n'
printf 'Official quota may be consumed. Type USE_OFFICIAL to continue: '
read -r confirmation
[[ "$confirmation" == 'USE_OFFICIAL' ]] || { printf 'cancelled\n'; exit 1; }

restore_remote_defaults "$CODEX_HOME_DIR/config.toml" "$BACKUP_DIR/config.toml"
systemctl stop codex-remote-provider.service || true
"$CODEX_BIN_PATH" remote-control stop --json >/dev/null 2>&1 || true
"$CODEX_BIN_PATH" remote-control start --json
printf 'Remote started with the normal/default Codex provider.\n'
