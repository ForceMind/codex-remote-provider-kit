#!/bin/sh
set -eu

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

repo_slug=${CODEX_RP_REPO:-ForceMind/codex-remote-provider-kit}
repo_ref=${CODEX_RP_REF:-main}
platform_name=${CODEX_RP_TEST_PLATFORM:-$(uname -s)}
case "$platform_name" in
  Linux)
    default_install_dir='/opt/codex-remote-provider-kit'
    platform_entry='panel.sh'
    ;;
  Darwin)
    default_install_dir="${HOME}/Library/Application Support/CodexRemoteProviderKit/app"
    platform_entry='platform/macos/codex-rp.sh'
    ;;
  *)
    die '此 Shell 安装入口支持 Linux/macOS；Windows 请使用 install-windows.ps1'
    ;;
esac
install_dir=${CODEX_RP_INSTALL_DIR:-$default_install_dir}
archive_url=${CODEX_RP_ARCHIVE_URL:-https://github.com/${repo_slug}/archive/refs/heads/${repo_ref}.tar.gz}

command -v curl >/dev/null 2>&1 || die '缺少 curl，请先安装后重试'
command -v tar >/dev/null 2>&1 || die '缺少 tar，请先安装后重试'
command -v bash >/dev/null 2>&1 || die '缺少 Bash，请先安装后重试'
command -v cksum >/dev/null 2>&1 || die '缺少 cksum，请先安装后重试'
case "$install_dir" in
  /|/opt|/usr|/root|/home) die '安装目录范围过大，已拒绝执行' ;;
  /*) ;;
  *) die '安装目录必须是绝对路径' ;;
esac
install_parent=$(dirname "$install_dir")

permission_probe=$install_parent
while [ ! -d "$permission_probe" ]; do
  next_probe=$(dirname "$permission_probe")
  [ "$next_probe" != "$permission_probe" ] || break
  permission_probe=$next_probe
done

if [ "$(id -u)" -eq 0 ] || [ -w "$permission_probe" ]; then
  run_as_root=''
else
  command -v sudo >/dev/null 2>&1 || die '需要 root 权限，但系统中没有 sudo'
  run_as_root='sudo'
fi

temp_dir=$(mktemp -d)
cleanup() {
  rm -rf "$temp_dir"
  if [ -n "${staging_dir:-}" ]; then
    $run_as_root rm -rf "$staging_dir"
  fi
}
trap cleanup 0

archive_file="$temp_dir/source.tar.gz"
say "正在下载 ${repo_slug}（${repo_ref}）……"
curl -fsSL "$archive_url" -o "$archive_file"
archive_source_id=$(cksum < "$archive_file")

source_root=$(tar -tzf "$archive_file" | sed -n '1{s:/$::;p;}')
[ -n "$source_root" ] || die '下载的压缩包结构无效'
case "$source_root" in
  */*|.*|'') die '下载的压缩包顶层目录不安全' ;;
esac

tar -xzf "$archive_file" -C "$temp_dir"
source_dir="$temp_dir/$source_root"
[ -x "$source_dir/$platform_entry" ] || die "压缩包中缺少可执行的 $platform_entry"
printf '%s\n' "$archive_source_id" > "$source_dir/.codex-rp-source-id"

installed_source_id=''
if $run_as_root test -f "$install_dir/.codex-rp-source-id"; then
  installed_source_id=$($run_as_root sed -n '1p' "$install_dir/.codex-rp-source-id" 2>/dev/null || :)
fi
if [ "$installed_source_id" = "$archive_source_id" ]; then
  say '当前已是最新套件版本。'
else
  timestamp=$(date +%Y%m%d-%H%M%S)
  staging_dir="${install_parent}/.codex-remote-provider-kit.new-${timestamp}-$$"
  backup_dir="${install_dir}.backup-${timestamp}-$$"

  $run_as_root install -d -m 755 "$install_parent"
  $run_as_root install -d -m 755 "$staging_dir"
  $run_as_root cp -a "$source_dir/." "$staging_dir/"

  if $run_as_root test -e "$install_dir"; then
    $run_as_root mv "$install_dir" "$backup_dir"
    say "旧版本已备份到：$backup_dir"
  fi

  if ! $run_as_root mv "$staging_dir" "$install_dir"; then
    if $run_as_root test -e "$backup_dir"; then
      $run_as_root mv "$backup_dir" "$install_dir"
    fi
    die '安装目录替换失败，已尝试恢复旧版本'
  fi
fi

say "工具已安装到：$install_dir"
say '完成首次面板初始化后，可在任意目录运行：codex-rp'

if [ "${CODEX_RP_NO_LAUNCH:-0}" = 1 ]; then
  exit 0
fi

if ( : </dev/tty ) 2>/dev/null; then
  say '正在打开中文安装面板……'
  cleanup
  trap - 0
  exec "$install_dir/$platform_entry" menu </dev/tty >/dev/tty
fi

say '当前没有交互式终端，请稍后运行：'
if [ "$platform_name" = Darwin ]; then
  say "  \"$install_dir/$platform_entry\" menu"
else
  say "  sudo $install_dir/setup.sh menu"
fi
