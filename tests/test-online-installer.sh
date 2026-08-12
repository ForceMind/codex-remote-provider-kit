#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
repo_parent=$(dirname "$repo_dir")
temp_dir=$(mktemp -d)
cleanup() { rm -rf "$temp_dir"; }
trap cleanup EXIT

archive_file="$temp_dir/source.tar.gz"
second_archive="$temp_dir/source-v2.tar.gz"
install_dir="$temp_dir/installed-kit"

tar --exclude='codex-remote-provider-kit/.git' \
  --exclude='codex-remote-provider-kit/.git/**' \
  -czf "$archive_file" -C "$repo_parent" codex-remote-provider-kit

CODEX_RP_ARCHIVE_URL="file://$archive_file" \
CODEX_RP_INSTALL_DIR="$install_dir" \
CODEX_RP_NO_LAUNCH=1 \
  sh "$repo_dir/install.sh" > "$temp_dir/first-install.log"

[[ -x "$install_dir/panel.sh" ]]
[[ -x "$install_dir/install-codex.sh" ]]
[[ -x "$install_dir/auto-update.sh" ]]
[[ -s "$install_dir/.codex-rp-source-id" ]]
grep -Fq '工具已安装到' "$temp_dir/first-install.log"

printf '旧版本标记\n' > "$install_dir/test-marker"
CODEX_RP_ARCHIVE_URL="file://$archive_file" \
CODEX_RP_INSTALL_DIR="$install_dir" \
CODEX_RP_NO_LAUNCH=1 \
  sh "$repo_dir/install.sh" > "$temp_dir/no-change.log"

[[ -f "$install_dir/test-marker" ]]
grep -Fq '当前已是最新套件版本' "$temp_dir/no-change.log"
if find "$temp_dir" -maxdepth 1 -type d -name 'installed-kit.backup-*' | grep -q .; then
  printf '未变更的在线版本不应生成备份\n' >&2
  exit 1
fi

mkdir -p "$temp_dir/v2"
tar -xzf "$archive_file" -C "$temp_dir/v2"
printf '新版本\n' > "$temp_dir/v2/codex-remote-provider-kit/release-marker"
tar -czf "$second_archive" -C "$temp_dir/v2" codex-remote-provider-kit
# 用不同归档模拟 main 出现新提交。
CODEX_RP_ARCHIVE_URL="file://$second_archive" \
CODEX_RP_INSTALL_DIR="$install_dir" \
CODEX_RP_NO_LAUNCH=1 \
  sh "$repo_dir/install.sh" > "$temp_dir/second-install.log"

backup_dir=$(find "$temp_dir" -maxdepth 1 -type d \
  -name 'installed-kit.backup-*' -print -quit)
[[ -n "$backup_dir" && -f "$backup_dir/test-marker" ]]
[[ -f "$install_dir/release-marker" ]]
grep -Fq '旧版本已备份到' "$temp_dir/second-install.log"

mock_bin="$temp_dir/mock-bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/sudo" <<'EOF'
#!/bin/sh
printf 'macOS 用户目录安装不应调用 sudo\n' >&2
exit 97
EOF
chmod 755 "$mock_bin/sudo"

# 模拟全新 Mac：CodexRemoteProviderKit 这一级目录尚不存在。
mac_install_dir="$temp_dir/macos-home/Library/Application Support/CodexRemoteProviderKit/app"
CODEX_RP_TEST_PLATFORM=Darwin \
CODEX_RP_ARCHIVE_URL="file://$archive_file" \
CODEX_RP_INSTALL_DIR="$mac_install_dir" \
CODEX_RP_NO_LAUNCH=1 \
PATH="$mock_bin:$PATH" \
  sh "$repo_dir/install.sh" > "$temp_dir/macos-install.log"

[[ -x "$mac_install_dir/platform/macos/codex-rp.sh" ]]
[[ -s "$mac_install_dir/.codex-rp-source-id" ]]
grep -Fq '工具已安装到' "$temp_dir/macos-install.log"

printf '在线安装器：通过\n'
