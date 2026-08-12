#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d)
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

install_dir="$test_dir/installed-kit"
mkdir -p "$install_dir"
install_dir=$(cd -- "$install_dir" && pwd -P)
cp "$repo_dir/auto-update.sh" "$install_dir/auto-update.sh"
chmod 755 "$install_dir/auto-update.sh"
printf 'source-id\n' > "$install_dir/.codex-rp-source-id"

fake_installer="$test_dir/fake-installer.sh"
cat > "$fake_installer" <<'EOF'
#!/bin/sh
set -eu
[ "$CODEX_RP_NO_LAUNCH" = 1 ]
[ "$CODEX_RP_INSTALL_DIR" = "$EXPECTED_INSTALL_DIR" ]
printf '%s\n' "$CODEX_RP_REPO@$CODEX_RP_REF" > "$CODEX_RP_INSTALL_DIR/update-result"
EOF
chmod 755 "$fake_installer"

EXPECTED_INSTALL_DIR="$install_dir" \
CODEX_RP_INSTALLER_URL="file://$fake_installer" \
CODEX_RP_REPO=example/kit \
CODEX_RP_REF=stable \
  "$install_dir/auto-update.sh" > "$test_dir/success.log" 2>&1
grep -Fxq 'example/kit@stable' "$install_dir/update-result"
grep -Fq '自动更新检查完成' "$test_dir/success.log"

rm -f "$install_dir/update-result"
CODEX_RP_INSTALLER_URL="file://$test_dir/missing-installer.sh" \
  "$install_dir/auto-update.sh" > "$test_dir/failure.log" 2>&1
[[ ! -e "$install_dir/update-result" ]]
grep -Fq '将继续使用当前版本' "$test_dir/failure.log"

invalid_installer="$test_dir/invalid-installer.sh"
printf 'if then\n' > "$invalid_installer"
CODEX_RP_INSTALLER_URL="file://$invalid_installer" \
  "$install_dir/auto-update.sh" > "$test_dir/invalid.log" 2>&1
grep -Fq '语法校验失败' "$test_dir/invalid.log"

mkdir "$install_dir.update-lock"
printf '%s\n' "$$" > "$install_dir.update-lock/pid"
CODEX_RP_INSTALLER_URL="file://$fake_installer" \
  "$install_dir/auto-update.sh" > "$test_dir/locked.log" 2>&1
grep -Fq '已在另一个进程中运行' "$test_dir/locked.log"
rm -f "$install_dir.update-lock/pid"
rmdir "$install_dir.update-lock"

CODEX_RP_SKIP_AUTO_UPDATE=1 \
CODEX_RP_INSTALLER_URL="file://$fake_installer" \
  "$install_dir/auto-update.sh" > "$test_dir/skipped.log" 2>&1
[[ ! -e "$install_dir/update-result" ]]
[[ ! -s "$test_dir/skipped.log" ]]

unmanaged_dir="$test_dir/git-checkout"
mkdir -p "$unmanaged_dir"
cp "$repo_dir/auto-update.sh" "$unmanaged_dir/auto-update.sh"
chmod 755 "$unmanaged_dir/auto-update.sh"
EXPECTED_INSTALL_DIR="$unmanaged_dir" \
CODEX_RP_INSTALLER_URL="file://$fake_installer" \
  "$unmanaged_dir/auto-update.sh" > "$test_dir/unmanaged.log" 2>&1
[[ ! -e "$unmanaged_dir/update-result" ]]

printf '自动更新器：通过\n'
