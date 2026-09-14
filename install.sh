#!/bin/sh
set -eu

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

# Network limits are deliberately bounded so a launcher never waits indefinitely.
# They may be overridden for constrained networks, but must remain positive integers.
download_connect_timeout=${CODEX_RP_DOWNLOAD_CONNECT_TIMEOUT:-10}
download_max_time=${CODEX_RP_DOWNLOAD_MAX_TIME:-60}
download_retries=${CODEX_RP_DOWNLOAD_RETRIES:-2}
download_retry_delay=${CODEX_RP_DOWNLOAD_RETRY_DELAY:-1}
for limit in "$download_connect_timeout" "$download_max_time" "$download_retries" "$download_retry_delay"; do
  case "$limit" in ''|*[!0-9]*) die '下载超时和重试参数必须是非负整数' ;; esac
done
[ "$download_connect_timeout" -gt 0 ] || die '下载连接超时必须大于零'
[ "$download_max_time" -gt 0 ] || die '下载总超时必须大于零'

repo_slug=${CODEX_RP_REPO:-ForceMind/codex-remote-provider-kit}
channel=${CODEX_RP_CHANNEL:-development}
case "$channel" in
  stable|development) ;;
  *) die '更新通道只能是 stable 或 development' ;;
esac
repo_ref=${CODEX_RP_REF:-}
if [ -z "$repo_ref" ]; then
  if [ "$channel" = development ]; then repo_ref=main; else repo_ref=release; fi
fi
platform_name=${CODEX_RP_TEST_PLATFORM:-$(uname -s)}
case "$platform_name" in
  Linux) default_install_dir='/opt/codex-remote-provider-kit'; platform_entry='panel.sh' ;;
  Darwin) default_install_dir="${HOME}/Library/Application Support/CodexRemoteProviderKit/app"; platform_entry='platform/macos/codex-rp.sh' ;;
  *) die '此 Shell 安装入口支持 Linux/macOS；Windows 请使用 install-windows.ps1' ;;
esac
install_dir=${CODEX_RP_INSTALL_DIR:-$default_install_dir}

# Stable releases resolve only through a Release asset, never the moving main
# branch. Development is intentionally explicit and may follow main.
if [ "$channel" = stable ]; then
  default_manifest_url="https://github.com/${repo_slug}/releases/latest/download/codex-rp-manifest.json"
else
  default_manifest_url="https://raw.githubusercontent.com/${repo_slug}/${repo_ref}/codex-rp-manifest.json"
fi
manifest_url_explicit=${CODEX_RP_MANIFEST_URL+x}
manifest_url=${CODEX_RP_MANIFEST_URL:-$default_manifest_url}
archive_url_override=${CODEX_RP_ARCHIVE_URL:-}
archive_sha256_override=${CODEX_RP_ARCHIVE_SHA256:-}

command -v curl >/dev/null 2>&1 || die '缺少 curl，请先安装后重试'
command -v tar >/dev/null 2>&1 || die '缺少 tar，请先安装后重试'
command -v bash >/dev/null 2>&1 || die '缺少 Bash，请先安装后重试'
case "$install_dir" in /|/opt|/usr|/root|/home) die '安装目录范围过大，已拒绝执行' ;; /*) ;; *) die '安装目录必须是绝对路径' ;; esac
install_parent=$(dirname "$install_dir")

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else die '缺少 SHA-256 工具（sha256sum、shasum 或 openssl）'; fi
}
download_file() {
  # curl retries only transient failures and honors both connection and total bounds.
  curl --fail --silent --show-error --location --connect-timeout "$download_connect_timeout" \
    --max-time "$download_max_time" --retry "$download_retries" --retry-delay "$download_retry_delay" \
    --retry-connrefused "$1" -o "$2"
}
manifest_value() {
  # Manifest fields are one JSON string per line; reject duplicates or malformed values.
  value=$(grep -E "^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"[[:space:]]*,?[[:space:]]*$" "$manifest_file" | sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p")
  [ "$(printf '%s\n' "$value" | wc -l | tr -d ' ')" = 1 ] || return 1
  printf '%s\n' "$value"
}

permission_probe=$install_parent
while [ ! -d "$permission_probe" ]; do next_probe=$(dirname "$permission_probe"); [ "$next_probe" != "$permission_probe" ] || break; permission_probe=$next_probe; done
if [ "$(id -u)" -eq 0 ] || [ -w "$permission_probe" ]; then run_as_root=''; else command -v sudo >/dev/null 2>&1 || die '需要 root 权限，但系统中没有 sudo'; run_as_root='sudo'; fi

temp_dir=$(mktemp -d)
staging_dir=''
cleanup() { rm -rf "$temp_dir"; [ -z "$staging_dir" ] || $run_as_root rm -rf "$staging_dir"; }
trap cleanup 0

archive_file="$temp_dir/source.tar.gz"
manifest_file="$temp_dir/manifest.json"
if [ -n "$archive_url_override" ]; then
  archive_url=$archive_url_override
  expected_sha256=$archive_sha256_override
  [ -n "$expected_sha256" ] || die '显式 CODEX_RP_ARCHIVE_URL 必须同时提供 CODEX_RP_ARCHIVE_SHA256'
  manifest_version='legacy-override'
  manifest_revision=$repo_ref
else
  say "正在获取 ${channel} 发布清单……"
  if ! download_file "$manifest_url" "$manifest_file"; then
    if [ "$channel" = development ] && [ -z "$manifest_url_explicit" ]; then
      say 'development 清单尚未发布；本次使用 GitHub main 归档。此兼容路径依赖 GitHub HTTPS，不提供独立制品校验。'
      archive_url="https://github.com/${repo_slug}/archive/refs/heads/${repo_ref}.tar.gz"
      download_file "$archive_url" "$archive_file" || die '无法下载 development 归档'
      expected_sha256=$(sha256_file "$archive_file")
      manifest_version='development-unpinned'
      manifest_revision=$repo_ref
    else
      die "无法下载 ${channel} 发布清单；stable 只接受已发布的 Release 清单"
    fi
  fi
  if [ -s "$manifest_file" ]; then
    manifest_channel=$(manifest_value channel) || die '发布清单格式无效：缺少或重复 channel'
    [ "$manifest_channel" = "$channel" ] || die '发布清单通道与请求通道不一致'
    archive_url=$(manifest_value archive_url) || die '发布清单格式无效：缺少 archive_url'
    expected_sha256=$(manifest_value archive_sha256) || die '发布清单格式无效：缺少 archive_sha256'
    manifest_version=$(manifest_value version) || die '发布清单格式无效：缺少 version'
    manifest_revision=$(manifest_value source_revision) || die '发布清单格式无效：缺少 source_revision'
  fi
fi
printf '%s\n' "$expected_sha256" | grep -Eq '^[0-9a-fA-F]{64}$' || die '发布清单 SHA-256 必须为 64 位十六进制值'
case "$archive_url" in https://*|file://*) ;; *) die '发布清单 archive_url 必须使用 HTTPS（测试可使用 file://）' ;; esac

say "正在下载 ${repo_slug}（${channel}：${manifest_version}）……"
if [ ! -s "$archive_file" ]; then
  download_file "$archive_url" "$archive_file" || die '无法下载发布归档'
fi
actual_sha256=$(sha256_file "$archive_file")
[ "$actual_sha256" = "$expected_sha256" ] || die '发布归档 SHA-256 校验失败，安装目录未改动'

source_root=$(tar -tzf "$archive_file" | sed -n '1{s:/$::;p;}')
[ -n "$source_root" ] || die '下载的压缩包结构无效'
case "$source_root" in */*|.*|'') die '下载的压缩包顶层目录不安全' ;; esac
# Every member must stay below the sole declared root; tar extraction then occurs
# only after the hash and structure have both passed.
if tar -tzf "$archive_file" | grep -Ev "^${source_root}(/|$)" >/dev/null; then die '下载的压缩包包含多个或不安全的顶层路径'; fi
tar -xzf "$archive_file" -C "$temp_dir"
source_dir="$temp_dir/$source_root"
[ -x "$source_dir/$platform_entry" ] || die "压缩包中缺少可执行的 $platform_entry"
printf '%s\n' "$actual_sha256" > "$source_dir/.codex-rp-source-id"
printf '{\n  "schema_version": "1",\n  "channel": "%s",\n  "version": "%s",\n  "source_revision": "%s",\n  "archive_sha256": "%s",\n  "manifest_url": "%s"\n}\n' "$channel" "$manifest_version" "$manifest_revision" "$actual_sha256" "$manifest_url" > "$source_dir/.codex-rp-source.json"

installed_source_id=''
if $run_as_root test -f "$install_dir/.codex-rp-source-id"; then installed_source_id=$($run_as_root sed -n '1p' "$install_dir/.codex-rp-source-id" 2>/dev/null || :); fi
if [ "$installed_source_id" = "$actual_sha256" ]; then
  say '当前已是最新套件版本。'
else
  timestamp=$(date +%Y%m%d-%H%M%S); staging_dir="${install_parent}/.codex-remote-provider-kit.new-${timestamp}-$$"; backup_dir="${install_dir}.backup-${timestamp}-$$"
  $run_as_root install -d -m 755 "$install_parent"; $run_as_root install -d -m 755 "$staging_dir"; $run_as_root cp -a "$source_dir/." "$staging_dir/"
  if $run_as_root test -e "$install_dir"; then $run_as_root mv "$install_dir" "$backup_dir"; say "旧版本已备份到：$backup_dir"; fi
  if ! $run_as_root mv "$staging_dir" "$install_dir"; then [ ! -e "$backup_dir" ] || $run_as_root mv "$backup_dir" "$install_dir"; die '安装目录替换失败，已尝试恢复旧版本'; fi
  staging_dir=''
fi

say "工具已安装到：$install_dir"
say '完成首次面板初始化后，可在任意目录运行：codex-rp'
[ "${CODEX_RP_NO_LAUNCH:-0}" = 1 ] && exit 0
if ( : </dev/tty ) 2>/dev/null; then say '正在打开中文安装面板……'; cleanup; trap - 0; exec "$install_dir/$platform_entry" menu </dev/tty >/dev/tty; fi
say '当前没有交互式终端，请稍后运行：'
if [ "$platform_name" = Darwin ]; then say "  \"$install_dir/$platform_entry\" menu"; else say "  sudo $install_dir/setup.sh menu"; fi
