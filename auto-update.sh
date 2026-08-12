#!/usr/bin/env bash
set -u

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source_marker="$script_dir/.codex-rp-source-id"

# Only archives installed by install.sh carry this marker. A Git checkout or a
# manually unpacked development tree must never be replaced behind the user's
# back.
[[ -f "$source_marker" ]] || exit 0
[[ ${CODEX_RP_SKIP_AUTO_UPDATE:-0} != 1 ]] || exit 0

warn() { printf '警告：自动更新失败，将继续使用当前版本：%s\n' "$*" >&2; }

repo_slug=${CODEX_RP_REPO:-ForceMind/codex-remote-provider-kit}
repo_ref=${CODEX_RP_REF:-main}
installer_url=${CODEX_RP_INSTALLER_URL:-https://raw.githubusercontent.com/${repo_slug}/${repo_ref}/install.sh}
lock_dir="${script_dir}.update-lock"
lock_owner="$lock_dir/pid"
lock_acquired='no'
temporary_dir=''

cleanup() {
  [[ -z "$temporary_dir" ]] || rm -rf "$temporary_dir"
  if [[ "$lock_acquired" == yes ]]; then
    rm -f "$lock_owner"
    rmdir "$lock_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_lock() {
  local existing_pid=''

  if mkdir "$lock_dir" 2>/dev/null; then
    lock_acquired='yes'
  else
    if [[ -r "$lock_owner" ]]; then
      IFS= read -r existing_pid < "$lock_owner" || existing_pid=''
    fi
    if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
      printf '自动更新检查已在另一个进程中运行，本次直接使用当前版本。\n' >&2
      return 1
    fi
    rm -f "$lock_owner" 2>/dev/null || return 1
    rmdir "$lock_dir" 2>/dev/null || return 1
    mkdir "$lock_dir" 2>/dev/null || return 1
    lock_acquired='yes'
  fi
  if ! printf '%s\n' "$$" > "$lock_owner"; then
    lock_acquired='yes'
    return 1
  fi
}

if ! acquire_lock; then
  exit 0
fi

command -v curl >/dev/null 2>&1 || { warn '系统中没有 curl'; exit 0; }
temporary_dir=$(mktemp -d) || { warn '无法创建临时目录'; exit 0; }
installer_file="$temporary_dir/install.sh"

printf '正在检查 Codex Remote Provider Kit 更新……\n'
if ! curl -fsSL "$installer_url" -o "$installer_file"; then
  warn '无法下载官方安装器'
  exit 0
fi
if ! sh -n "$installer_file"; then
  warn '下载的安装器语法校验失败'
  exit 0
fi

if ! CODEX_RP_INSTALL_DIR="$script_dir" \
    CODEX_RP_NO_LAUNCH=1 \
    CODEX_RP_REPO="$repo_slug" \
    CODEX_RP_REF="$repo_ref" \
    sh "$installer_file"; then
  warn '安装器未能完成事务更新'
  exit 0
fi

printf '自动更新检查完成。\n'
