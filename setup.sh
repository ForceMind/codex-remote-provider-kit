#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  cat <<'EOF'
Codex Remote third-party provider manager

Usage:
  sudo ./setup.sh [command] [install options]

Commands:
  install       Install, start, and run a full verification (default)
  status        Show service and configuration status without model generation
  test          Run endpoint checks and one minimal real Codex turn
  official      Manually switch Remote to the default/official provider
  third-party   Start or switch Remote to the installed third-party provider
  rollback      Restore the pre-install configuration and remove the saved key
  help          Show this help

Default install settings:
  Base URL:     https://ai.inno-flare.com/v1
  Model:        gpt-5.6-sol
  Provider ID:  inno_flare
  Codex home:   /root/.codex

Examples:
  sudo ./setup.sh
  sudo ./setup.sh test
  sudo ./setup.sh official
  sudo ./setup.sh install --model gpt-5.5 --reasoning medium

The installer asks for the provider key without echoing it. Never pass a key
as a command-line argument or save one in this repository.
EOF
}

command_name=${1:-install}
if (($#)); then shift; fi

case "$command_name" in
  help|-h|--help) usage; exit 0 ;;
  install|status|test|official|third-party|start|rollback) ;;
  *)
    printf 'error: unknown command: %s\n\n' "$command_name" >&2
    usage >&2
    exit 2
    ;;
esac

if ((EUID != 0)); then
  command -v sudo >/dev/null 2>&1 || {
    printf 'error: root is required and sudo is unavailable\n' >&2
    exit 1
  }
  exec sudo "$script_dir/setup.sh" "$command_name" "$@"
fi

case "$command_name" in
  install)
    if [[ -r /var/lib/codex-remote-provider/state.env ]]; then
      if (($#)); then
        printf 'error: provider kit is already installed; extra install options were not applied\n' >&2
        printf 'run sudo ./rollback.sh before reinstalling with different settings\n' >&2
        exit 1
      fi
      printf 'Existing installation detected; restarting the third-party Remote service.\n'
      "$script_dir/use-third-party.sh"
    else
      "$script_dir/install.sh" \
        --base-url https://ai.inno-flare.com/v1 \
        --model gpt-5.6-sol \
        --provider-id inno_flare \
        --codex-home /root/.codex \
        "$@"
    fi
    printf '\nRunning full verification...\n'
    "$script_dir/status.sh" --full
    printf '\nReady. Create a new phone chat and send: Reply exactly OK\n'
    ;;
  status)
    (($# == 0)) || { printf 'error: status takes no options\n' >&2; exit 2; }
    "$script_dir/status.sh"
    ;;
  test)
    (($# == 0)) || { printf 'error: test takes no options\n' >&2; exit 2; }
    "$script_dir/status.sh" --full
    ;;
  official)
    (($# == 0)) || { printf 'error: official takes no options\n' >&2; exit 2; }
    "$script_dir/use-official.sh"
    ;;
  third-party|start)
    (($# == 0)) || { printf 'error: third-party takes no options\n' >&2; exit 2; }
    "$script_dir/use-third-party.sh"
    "$script_dir/status.sh"
    ;;
  rollback)
    (($# == 0)) || { printf 'error: rollback takes no options\n' >&2; exit 2; }
    "$script_dir/rollback.sh"
    ;;
esac
