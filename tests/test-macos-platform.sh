#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d)
cleanup() {
  if [[ ${CODEX_RP_KEEP_TEST_DIR:-0} == 1 ]]; then
    printf '已保留 macOS 测试目录：%s\n' "$test_dir" >&2
  else
    rm -rf "$test_dir"
  fi
}
trap cleanup EXIT

mock_bin="$test_dir/bin"
mock_keychain="$test_dir/keychain-value"
mock_codex="$mock_bin/codex"
mkdir -p "$mock_bin" "$test_dir/home/.codex"

cat > "$mock_bin/security" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command_name=${1-}
shift || true
case "$command_name" in
  -i)
    IFS= read -r command_line
    [[ "$command_line" == add-generic-password\ -U\ -a\ third_party\ -s\ codex-remote-provider-kit:third_party\ -w\ * ]]
    value=${command_line##* -w }
    [[ -n "$value" ]]
    printf '%s' "$value" > "$MOCK_KEYCHAIN_FILE"
    chmod 600 "$MOCK_KEYCHAIN_FILE"
    ;;
  find-generic-password)
    [[ " $* " == *' -a third_party '* ]]
    [[ " $* " == *' -s codex-remote-provider-kit:third_party '* ]]
    [[ -f "$MOCK_KEYCHAIN_FILE" ]] || exit 44
    if [[ " $* " == *' -w '* ]]; then
      cat "$MOCK_KEYCHAIN_FILE"
    fi
    ;;
  add-generic-password)
    printf '密钥不应通过 security 命令行参数写入\n' >&2
    exit 2
    ;;
  delete-generic-password)
    [[ " $* " == *' -a third_party '* ]]
    [[ " $* " == *' -s codex-remote-provider-kit:third_party '* ]]
    rm -f "$MOCK_KEYCHAIN_FILE"
    ;;
  *) exit 2 ;;
esac
EOF

cat > "$mock_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case ${1-} in
  --version) printf 'codex-cli test\n' ;;
  login)
    [[ ${2-} == status ]]
    printf 'Logged in using ChatGPT\n'
    ;;
  exec)
    shift
    output_file=''
    while (($#)); do
      if [[ $1 == --output-last-message ]]; then
        output_file=${2:?}
        shift 2
      else
        shift
      fi
    done
    [[ -n "$output_file" ]]
    printf 'OK\n' > "$output_file"
    ;;
  *) exit 2 ;;
esac
EOF

cat > "$mock_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$mock_bin/security" "$mock_codex" "$mock_bin/pgrep"

config_file="$test_dir/home/.codex/config.toml"
original_config="$test_dir/original-config.toml"
cat > "$config_file" <<'EOF'
model_provider = 'openai'
model = "official-model"
model_reasoning_effort = "medium"

[features]
shell_tool = true
EOF
cp "$config_file" "$original_config"

common_env=(
  PATH="$mock_bin:$PATH"
  HOME="$test_dir/home"
  CODEX_HOME="$test_dir/home/.codex"
  CODEX_RP_DATA_DIR="$test_dir/data"
  CODEX_RP_COMMAND_FILE="$test_dir/bin/codex-rp"
  CODEX_RP_SECURITY_BIN="$mock_bin/security"
  CODEX_RP_TEST_PLATFORM=Darwin
  CODEX_RP_SKIP_CODEX_INSTALL=1
  CODEX_RP_TEST_MODE=1
  MOCK_KEYCHAIN_FILE="$mock_keychain"
)

set_top_level_for_test() {
  local target=${1:?target required}
  local key=${2:?key required}
  local value=${3:?value required}
  local temp_file="$target.test-new"
  awk -v key="$key" -v value="$value" '
    BEGIN { in_top=1 }
    in_top && /^[[:space:]]*\[/ { in_top=0 }
    in_top && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      print key " = \"" value "\""
      next
    }
    { print }
  ' "$target" > "$temp_file"
  mv -f "$temp_file" "$target"
}

cat > "$config_file" <<'EOF'
model_provider = "cc_switch_proxy"
model = "cc-switch-model"
model_reasoning_effort = "low"

[model_providers.cc_switch_proxy]
name = "CC Switch test provider"
base_url = "https://cc-switch.test/v1"
wire_api = "responses"
EOF
cp "$config_file" "$test_dir/external-before-install.toml"
if env "${common_env[@]}" THIRD_PARTY_API_KEY='test_token' \
  bash "$repo_dir/platform/macos/codex-rp.sh" install \
    --base-url https://gateway.test/v1 --codex-bin "$mock_codex" \
    > "$test_dir/external-install.log" 2>&1; then
  printf 'macOS 安装器错误接受了 CC Switch 外部 provider\n' >&2
  exit 1
fi
grep -Fq '请先在 CC Switch 中切换到官方配置' \
  "$test_dir/external-install.log"
cmp -s "$config_file" "$test_dir/external-before-install.toml"
[[ ! -e "$mock_keychain" ]]
cp "$original_config" "$config_file"

cat >> "$config_file" <<'EOF'

[model_providers.third_party]
name = "CC Switch conflicting provider"
base_url = "https://cc-switch-conflict.test/v1"
wire_api = "responses"
EOF
if env "${common_env[@]}" THIRD_PARTY_API_KEY='test_token' \
  bash "$repo_dir/platform/macos/codex-rp.sh" install \
    --base-url https://gateway.test/v1 --codex-bin "$mock_codex" \
    > "$test_dir/provider-collision.log" 2>&1; then
  printf 'macOS 安装器错误覆盖了 CC Switch 同名 provider\n' >&2
  exit 1
fi
grep -Fq '请改用其他 Provider ID' "$test_dir/provider-collision.log"
[[ ! -e "$mock_keychain" ]]
cp "$original_config" "$config_file"

profile_file="$test_dir/home/.codex/third_party.config.toml"
printf 'CC Switch profile sentinel\n' > "$profile_file"
if env "${common_env[@]}" THIRD_PARTY_API_KEY='test_token' \
  bash "$repo_dir/platform/macos/codex-rp.sh" install \
    --base-url https://gateway.test/v1 --codex-bin "$mock_codex" \
    > "$test_dir/profile-collision.log" 2>&1; then
  printf 'macOS 安装器错误覆盖了 CC Switch 同名 profile\n' >&2
  exit 1
fi
grep -Fq '为避免覆盖 CC Switch 或其他工具的 profile' \
  "$test_dir/profile-collision.log"
grep -Fxq 'CC Switch profile sentinel' "$profile_file"
[[ ! -e "$mock_keychain" ]]
rm -f "$profile_file"

if env "${common_env[@]}" bash "$repo_dir/platform/macos/codex-rp.sh" install \
  --base-url https://api.example.com/v1 --codex-bin "$mock_codex" \
  > "$test_dir/example-url.log" 2>&1; then
  printf 'macOS 安装器错误接受了示例 Base URL\n' >&2
  exit 1
fi

env "${common_env[@]}" THIRD_PARTY_API_KEY='test_token' \
  bash "$repo_dir/platform/macos/codex-rp.sh" install \
    --base-url https://gateway.test/v1 \
    --model gpt-5.6-sol \
    --provider-id third_party \
    --reasoning high \
    --codex-bin "$mock_codex" > "$test_dir/install.log"
grep -Fq '官方配置预检：通过' "$test_dir/install.log"
grep -Fq '检测到外部 provider 时会拒绝覆盖' "$test_dir/install.log"

[[ -x "$test_dir/bin/codex-rp" ]]
app_bundle="$test_dir/home/Applications/Codex 远程模型服务工具.app"
legacy_app_bundle="$test_dir/home/Applications/Codex Remote Provider Kit.app"
[[ -x "$app_bundle/Contents/MacOS/codex-rp-launcher" ]]
/bin/bash -n "$app_bundle/Contents/MacOS/codex-rp-launcher"
/bin/bash -n "$app_bundle/Contents/Resources/launch.command"
grep -Fxq 'Managed by codex-remote-provider-kit:macos-app' \
  "$app_bundle/Contents/Resources/.codex-rp-managed"
grep -Fq 'com.forcemind.codex-remote-provider-kit' "$app_bundle/Contents/Info.plist"
grep -Fq '<string>Codex 远程模型服务工具</string>' "$app_bundle/Contents/Info.plist"
grep -Fq '<string>codex-rp.icns</string>' "$app_bundle/Contents/Info.plist"
cmp -s "$repo_dir/platform/macos/assets/codex-rp.icns" \
  "$app_bundle/Contents/Resources/codex-rp.icns"
grep -Fq 'open -a Terminal' "$app_bundle/Contents/MacOS/codex-rp-launcher"
LC_ALL=C grep -Fq 'codex-rp.sh' \
  "$app_bundle/Contents/Resources/launch.command"
grep -Fq 'auto-update.sh' "$app_bundle/Contents/Resources/launch.command"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$app_bundle/Contents/Info.plist" >/dev/null
fi
if command -v iconutil >/dev/null 2>&1; then
  iconutil --convert iconset --output "$test_dir/verified.iconset" \
    "$app_bundle/Contents/Resources/codex-rp.icns"
  [[ -f "$test_dir/verified.iconset/icon_512x512@2x.png" ]]
fi
[[ -f "$mock_keychain" ]]
[[ -d "$test_dir/data/active" ]]
grep -Fxq 'model_provider = "third_party"' "$config_file"
grep -Fxq 'model = "gpt-5.6-sol"' "$config_file"
grep -Fxq 'model_reasoning_effort = "high"' "$config_file"
grep -Fxq '[model_providers.third_party]' "$config_file"
grep -Fxq 'base_url = "https://gateway.test/v1"' "$config_file"
grep -Fxq "command = \"$mock_bin/security\"" "$config_file"
grep -Fxq 'args = ["find-generic-password", "-a", "third_party", "-s", "codex-remote-provider-kit:third_party", "-w"]' "$config_file"
! grep -Fq 'env_key' "$config_file"
! grep -Fq 'test_token' "$config_file"
grep -Fxq 'third_party' "$test_dir/data/active/keychain_account"
env "${common_env[@]}" "$test_dir/bin/codex-rp" help > "$test_dir/launcher-help.log"
grep -Fq 'Codex 远程模型服务工具（macOS）' "$test_dir/launcher-help.log"
grep -Fq 'auto-update.sh' "$test_dir/bin/codex-rp"

env "${common_env[@]}" bash "$repo_dir/platform/macos/codex-rp.sh" status \
  > "$test_dir/status-third.log"
grep -Fq '当前模式：third-party' "$test_dir/status-third.log"
grep -Fq 'ChatGPT 桌面应用：运行中' "$test_dir/status-third.log"

printf '2\n0\n' | env "${common_env[@]}" \
  bash "$repo_dir/platform/macos/codex-rp.sh" menu \
  > "$test_dir/menu-success.log" 2>&1
[[ $(grep -Fc 'Codex 远程模型服务工具（macOS）' "$test_dir/menu-success.log") -eq 2 ]]
grep -Fq '操作完成，已返回主菜单。' "$test_dir/menu-success.log"

cp "$config_file" "$test_dir/managed-before-external-switch.toml"
set_top_level_for_test "$config_file" model_provider cc_switch_proxy
set_top_level_for_test "$config_file" model cc-switch-model
set_top_level_for_test "$config_file" model_reasoning_effort low
cp "$config_file" "$test_dir/external-after-install.toml"
if env "${common_env[@]}" \
  bash "$repo_dir/platform/macos/codex-rp.sh" third-party \
  > "$test_dir/external-third-party.log" 2>&1; then
  printf 'macOS 切换错误覆盖了 CC Switch 外部 provider\n' >&2
  exit 1
fi
grep -Fq '检测到 CC Switch 或其他工具选择了外部 provider' \
  "$test_dir/external-third-party.log"
cmp -s "$config_file" "$test_dir/external-after-install.toml"
if printf 'ROLLBACK\n' | env "${common_env[@]}" \
  bash "$repo_dir/platform/macos/codex-rp.sh" rollback \
  > "$test_dir/external-rollback.log" 2>&1; then
  printf 'macOS 回滚错误覆盖了 CC Switch 外部 provider\n' >&2
  exit 1
fi
grep -Fq '请先在外部工具中切换到 OpenAI 官方配置' \
  "$test_dir/external-rollback.log"
cmp -s "$config_file" "$test_dir/external-after-install.toml"
cp "$test_dir/managed-before-external-switch.toml" "$config_file"

printf 'y\n' | env "${common_env[@]}" \
  bash "$repo_dir/platform/macos/codex-rp.sh" official > "$test_dir/official.log"
grep -Fxq "model_provider = 'openai'" "$config_file"
grep -Fxq 'model = "official-model"' "$config_file"
grep -Fxq 'model_reasoning_effort = "medium"' "$config_file"
grep -Fxq '[model_providers.third_party]' "$config_file"

set_top_level_for_test "$config_file" model cc-official-model
set_top_level_for_test "$config_file" model_reasoning_effort low
env "${common_env[@]}" bash "$repo_dir/platform/macos/codex-rp.sh" third-party \
  > "$test_dir/third-party.log"
printf 'y\n' | env "${common_env[@]}" \
  bash "$repo_dir/platform/macos/codex-rp.sh" official \
  > "$test_dir/official-latest.log"
grep -Fxq "model_provider = 'openai'" "$config_file"
grep -Fxq 'model = "cc-official-model"' "$config_file"
grep -Fxq 'model_reasoning_effort = "low"' "$config_file"
env "${common_env[@]}" bash "$repo_dir/platform/macos/codex-rp.sh" third-party \
  > "$test_dir/third-party-latest.log"
env "${common_env[@]}" bash "$repo_dir/platform/macos/codex-rp.sh" test \
  > "$test_dir/test.log"
grep -Fq 'Codex 回复：OK' "$test_dir/test.log"

cat >> "$config_file" <<'EOF'

[model_providers.cc_switch_saved]
name = "CC Switch saved provider"
base_url = "https://cc-switch-saved.test/v1"
wire_api = "responses"
EOF

printf 'RESTART_APP\n' | env "${common_env[@]}" \
  bash "$repo_dir/platform/macos/codex-rp.sh" restart-app > "$test_dir/restart.log"
grep -Fq '已模拟重启 ChatGPT' "$test_dir/restart.log"

printf 'ROLLBACK\n' | env "${common_env[@]}" \
  bash "$repo_dir/platform/macos/codex-rp.sh" rollback > "$test_dir/rollback.log"
grep -Fxq "model_provider = 'openai'" "$config_file"
grep -Fxq 'model = "cc-official-model"' "$config_file"
grep -Fxq 'model_reasoning_effort = "low"' "$config_file"
grep -Fxq '[features]' "$config_file"
grep -Fxq '[model_providers.cc_switch_saved]' "$config_file"
grep -Fxq 'base_url = "https://cc-switch-saved.test/v1"' "$config_file"
! grep -Fq 'codex-remote-provider-kit:third_party' "$config_file"
! grep -Fxq '[model_providers.third_party]' "$config_file"
[[ ! -e "$mock_keychain" ]]
[[ ! -e "$test_dir/data/active" ]]
[[ ! -e "$test_dir/bin/codex-rp" ]]
[[ ! -e "$app_bundle" ]]
find "$test_dir/data/audit" -maxdepth 1 -type d -name 'state-*' | grep -q .

mkdir -p "$legacy_app_bundle/Contents/Resources"
printf 'Managed by codex-remote-provider-kit:macos-app\n' \
  > "$legacy_app_bundle/Contents/Resources/.codex-rp-managed"
env "${common_env[@]}" bash "$repo_dir/platform/macos/codex-rp.sh" shortcut \
  > "$test_dir/migrate-shortcut.log"
[[ ! -e "$legacy_app_bundle" ]]
[[ -x "$app_bundle/Contents/MacOS/codex-rp-launcher" ]]
grep -Fq 'Codex 远程模型服务工具.app' "$test_dir/migrate-shortcut.log"

printf '2\n0\n' | env "${common_env[@]}" \
  bash "$repo_dir/panel.sh" > "$test_dir/panel.log" 2>&1
[[ $(grep -Fc 'Codex 远程模型服务工具（macOS）' "$test_dir/panel.log") -eq 2 ]]
grep -Fq '操作失败，已返回主菜单。' "$test_dir/panel.log"
[[ -x "$test_dir/bin/codex-rp" ]]
[[ -x "$app_bundle/Contents/MacOS/codex-rp-launcher" ]]

rm -rf "$app_bundle"
mkdir -p "$app_bundle"
printf 'user app\n' > "$app_bundle/sentinel"
if env "${common_env[@]}" \
  bash "$repo_dir/platform/macos/codex-rp.sh" shortcut \
  > "$test_dir/unmanaged-app.log" 2>&1; then
  printf 'macOS 快捷入口错误覆盖了非受管应用\n' >&2
  exit 1
fi
grep -Fq '不由本套件管理' "$test_dir/unmanaged-app.log"
grep -Fxq 'user app' "$app_bundle/sentinel"

printf 'macOS platform lifecycle: ok\n'
