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
tar --exclude='codex-remote-provider-kit/.git' --exclude='codex-remote-provider-kit/.git/**' -czf "$archive_file" -C "$repo_parent" codex-remote-provider-kit
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
write_manifest() {
  local manifest=$1 archive=$2 channel=${3:-stable} revision=${4:-test-revision}
  printf '{\n  "channel": "%s",\n  "version": "1.0.0-test",\n  "source_revision": "%s",\n  "archive_url": "file://%s",\n  "archive_sha256": "%s"\n}\n' "$channel" "$revision" "$archive" "$(sha256 "$archive")" > "$manifest"
}
manifest="$temp_dir/manifest.json"
write_manifest "$manifest" "$archive_file"

CODEX_RP_CHANNEL=stable CODEX_RP_MANIFEST_URL="file://$manifest" CODEX_RP_INSTALL_DIR="$install_dir" CODEX_RP_NO_LAUNCH=1 sh "$repo_dir/install.sh" > "$temp_dir/first-install.log"
[[ -x "$install_dir/panel.sh" && -x "$install_dir/install-codex.sh" && -x "$install_dir/auto-update.sh" ]]
grep -Eq '^[0-9a-f]{64}$' "$install_dir/.codex-rp-source-id"
grep -Fq '"channel": "stable"' "$install_dir/.codex-rp-source.json"
grep -Fq '工具已安装到' "$temp_dir/first-install.log"

printf '旧版本标记\n' > "$install_dir/test-marker"
CODEX_RP_CHANNEL=stable CODEX_RP_MANIFEST_URL="file://$manifest" CODEX_RP_INSTALL_DIR="$install_dir" CODEX_RP_NO_LAUNCH=1 sh "$repo_dir/install.sh" > "$temp_dir/no-change.log"
[[ -f "$install_dir/test-marker" ]]
grep -Fq '当前已是最新套件版本' "$temp_dir/no-change.log"
! find "$temp_dir" -maxdepth 1 -type d -name 'installed-kit.backup-*' | grep -q .

mkdir -p "$temp_dir/v2"
tar -xzf "$archive_file" -C "$temp_dir/v2"
printf '新版本\n' > "$temp_dir/v2/codex-remote-provider-kit/release-marker"
tar -czf "$second_archive" -C "$temp_dir/v2" codex-remote-provider-kit
write_manifest "$manifest" "$second_archive" stable test-revision-2
CODEX_RP_CHANNEL=stable CODEX_RP_MANIFEST_URL="file://$manifest" CODEX_RP_INSTALL_DIR="$install_dir" CODEX_RP_NO_LAUNCH=1 sh "$repo_dir/install.sh" > "$temp_dir/second-install.log"
backup_dir=$(find "$temp_dir" -maxdepth 1 -type d -name 'installed-kit.backup-*' -print -quit)
[[ -n "$backup_dir" && -f "$backup_dir/test-marker" && -f "$install_dir/release-marker" ]]

# A bad manifest hash is rejected before extraction or replacement.
printf '旧版本标记\n' > "$install_dir/transaction-marker"
sed 's/[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' "$manifest" > "$temp_dir/bad-hash.json"
if CODEX_RP_CHANNEL=stable CODEX_RP_MANIFEST_URL="file://$temp_dir/bad-hash.json" CODEX_RP_INSTALL_DIR="$install_dir" CODEX_RP_NO_LAUNCH=1 sh "$repo_dir/install.sh" > "$temp_dir/bad-hash.log" 2>&1; then exit 1; fi
grep -Fq 'SHA-256 校验失败' "$temp_dir/bad-hash.log"
[[ -f "$install_dir/transaction-marker" ]]

# Missing stable Release manifests fail openly, rather than following main.
if CODEX_RP_CHANNEL=stable CODEX_RP_MANIFEST_URL="file://$temp_dir/no-release.json" CODEX_RP_INSTALL_DIR="$install_dir" CODEX_RP_NO_LAUNCH=1 sh "$repo_dir/install.sh" > "$temp_dir/missing-release.log" 2>&1; then exit 1; fi
grep -Fq 'stable 只接受已发布的 Release 清单' "$temp_dir/missing-release.log"

# Explicit development may intentionally use its own manifest/ref.
write_manifest "$temp_dir/development.json" "$archive_file" development main
CODEX_RP_CHANNEL=development CODEX_RP_MANIFEST_URL="file://$temp_dir/development.json" CODEX_RP_INSTALL_DIR="$temp_dir/development-kit" CODEX_RP_NO_LAUNCH=1 sh "$repo_dir/install.sh" >/dev/null
grep -Fq '"channel": "development"' "$temp_dir/development-kit/.codex-rp-source.json"

printf '在线安装器：通过\n'
