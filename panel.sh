#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
case "$(uname -s)" in
  Darwin) exec "$script_dir/platform/macos/codex-rp.sh" menu ;;
  Linux) exec "$script_dir/setup.sh" menu ;;
  *)
    printf 'Windows 请运行 platform\\windows\\codex-rp.ps1 或使用 install-windows.ps1。\n' >&2
    exit 1
    ;;
esac
