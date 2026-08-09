#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

((EUID == 0)) || { printf 'run as root\n' >&2; exit 1; }
state_file='/var/lib/codex-remote-provider/state.env'
[[ -r "$state_file" ]] || { printf 'state file missing; nothing to roll back\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"

printf 'Rollback will remove the persisted provider key and restore %s.\n' "$BACKUP_DIR"
printf 'Type ROLLBACK to continue: '
read -r confirmation
[[ "$confirmation" == 'ROLLBACK' ]] || { printf 'cancelled\n'; exit 1; }

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
  remove_default_provider "$CODEX_HOME_DIR/config.toml"
fi

if [[ -f "$BACKUP_DIR/profile.config.toml" ]]; then
  install -m 600 "$BACKUP_DIR/profile.config.toml" "$CODEX_HOME_DIR/$PROVIDER_ID.config.toml"
else
  rm -f "$CODEX_HOME_DIR/$PROVIDER_ID.config.toml"
fi

rm -f /etc/codex-remote-provider/provider.env
rm -f /etc/systemd/system/codex-remote-provider.service
systemctl daemon-reload

if [[ "$LEGACY_ENABLED" == yes ]]; then systemctl enable codex.service; fi
if [[ "$LEGACY_ACTIVE" == yes ]]; then systemctl start codex.service; fi
printf 'Rollback complete. State retained at %s for audit.\n' "$state_file"
