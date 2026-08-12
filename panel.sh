#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
command_name=${1:-menu}
if (($#)); then shift; fi
case "$(uname -s)" in
  Darwin) exec "$script_dir/platform/macos/codex-rp.sh" "$command_name" "$@" ;;
  Linux) exec "$script_dir/setup.sh" "$command_name" "$@" ;;
  *)
    printf 'Windows 请运行 platform\\windows\\codex-rp.ps1 或使用 install-windows.ps1。\n' >&2
    exit 1
    ;;
esac
