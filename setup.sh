#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  cat <<'EOF'
Codex Remote third-party provider manager

Usage:
  ./panel.sh
  codex-remote-provider
  sudo ./setup.sh [command] [install options]

Commands:
  menu          Open the interactive command panel
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
  ./panel.sh
  codex-remote-provider
  sudo ./setup.sh install
  sudo ./setup.sh test
  sudo ./setup.sh official
  sudo ./setup.sh install --model gpt-5.5 --reasoning medium

The installer asks for the provider key without echoing it. Never pass a key
as a command-line argument or save one in this repository.
EOF
}

command_name=${1:-menu}
if (($#)); then shift; fi

case "$command_name" in
  help|-h|--help) usage; exit 0 ;;
  menu|install|status|test|official|third-party|start|rollback) ;;
  *)
    printf 'error: unknown command: %s\n\n' "$command_name" >&2
    usage >&2
    exit 2
    ;;
esac

show_panel() {
  local choice
  while true; do
    printf '\n'
    printf 'Codex Remote Provider Kit\n'
    printf '=========================\n'
    printf '1) 一键安装 / 重启第三方 Remote\n'
    printf '2) 查看基础状态\n'
    printf '3) 运行完整连接测试\n'
    printf '4) 切换到第三方推理\n'
    printf '5) 切换到官方推理\n'
    printf '6) 完整回滚\n'
    printf '7) 查看帮助\n'
    printf '0) 退出\n'
    printf '请选择 [0-7]: '
    if ! read -r choice; then
      printf '\n输入已关闭，退出。\n'
      return 0
    fi
    case "$choice" in
      1) panel_install ;;
      2) "$script_dir/setup.sh" status ;;
      3) "$script_dir/setup.sh" test ;;
      4) "$script_dir/setup.sh" third-party ;;
      5) "$script_dir/setup.sh" official ;;
      6) "$script_dir/setup.sh" rollback ;;
      7) usage ;;
      0) return 0 ;;
      *) printf '无效选项，请输入 0 到 7。\n' >&2 ;;
    esac
  done
}

panel_install() {
  local base_url model provider_id reasoning input

  if [[ -r /var/lib/codex-remote-provider/state.env ]]; then
    "$script_dir/setup.sh" install
    return
  fi

  base_url='https://ai.inno-flare.com/v1'
  model='gpt-5.6-sol'
  provider_id='inno_flare'
  reasoning='high'

  printf 'Base URL [%s]: ' "$base_url"
  read -r input || return 1
  base_url=${input:-$base_url}
  printf '模型 [%s]: ' "$model"
  read -r input || return 1
  model=${input:-$model}
  printf 'Provider ID [%s]: ' "$provider_id"
  read -r input || return 1
  provider_id=${input:-$provider_id}
  printf '推理强度 none/minimal/low/medium/high/xhigh [%s]: ' "$reasoning"
  read -r input || return 1
  reasoning=${input:-$reasoning}

  "$script_dir/setup.sh" install \
    --base-url "$base_url" \
    --model "$model" \
    --provider-id "$provider_id" \
    --reasoning "$reasoning"
}

if ((EUID != 0)); then
  command -v sudo >/dev/null 2>&1 || {
    printf 'error: root is required and sudo is unavailable\n' >&2
    exit 1
  }
  exec sudo "$script_dir/setup.sh" "$command_name" "$@"
fi

case "$command_name" in
  menu)
    (($# == 0)) || { printf 'error: menu takes no options\n' >&2; exit 2; }
    show_panel
    ;;
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
