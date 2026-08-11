#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d)
cleanup() { rm -rf "$test_dir"; }
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
  find-generic-password)
    [[ -f "$MOCK_KEYCHAIN_FILE" ]] || exit 44
    if [[ " $* " == *' -w '* ]]; then
      cat "$MOCK_KEYCHAIN_FILE"
    fi
    ;;
  add-generic-password)
    value=''
    while (($#)); do
      if [[ $1 == -w ]]; then value=${2:?}; shift 2; else shift; fi
    done
    [[ -n "$value" ]]
    printf '%s' "$value" > "$MOCK_KEYCHAIN_FILE"
    chmod 600 "$MOCK_KEYCHAIN_FILE"
    ;;
  delete-generic-password)
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

[[ -x "$test_dir/bin/codex-rp" ]]
[[ -f "$mock_keychain" ]]
[[ -d "$test_dir/data/active" ]]
python3 - "$config_file" "$mock_bin/security" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "third_party"
assert config["model"] == "gpt-5.6-sol"
assert config["model_reasoning_effort"] == "high"
provider = config["model_providers"]["third_party"]
assert provider["base_url"] == "https://gateway.test/v1"
assert "env_key" not in provider
assert provider["auth"]["command"] == sys.argv[2]
assert provider["auth"]["args"][-2:] == ["codex-remote-provider-kit:third_party", "-w"]
assert "test_token" not in open(sys.argv[1], encoding="utf-8").read()
PY

env "${common_env[@]}" bash "$repo_dir/platform/macos/codex-rp.sh" status \
  > "$test_dir/status-third.log"
grep -Fq '当前模式：third-party' "$test_dir/status-third.log"
grep -Fq 'ChatGPT 桌面应用：运行中' "$test_dir/status-third.log"

printf 'y\n' | env "${common_env[@]}" \
  bash "$repo_dir/platform/macos/codex-rp.sh" official > "$test_dir/official.log"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "openai"
assert config["model"] == "official-model"
assert config["model_reasoning_effort"] == "medium"
assert "third_party" in config["model_providers"]
PY
env "${common_env[@]}" bash "$repo_dir/platform/macos/codex-rp.sh" status \
  > "$test_dir/status-baseline.log"
grep -Fq '当前模式：baseline' "$test_dir/status-baseline.log"

env "${common_env[@]}" bash "$repo_dir/platform/macos/codex-rp.sh" third-party \
  > "$test_dir/third-party.log"
env "${common_env[@]}" bash "$repo_dir/platform/macos/codex-rp.sh" test \
  > "$test_dir/test.log"
grep -Fq 'Codex 回复：OK' "$test_dir/test.log"

printf 'RESTART_APP\n' | env "${common_env[@]}" \
  bash "$repo_dir/platform/macos/codex-rp.sh" restart-app > "$test_dir/restart.log"
grep -Fq '已模拟重启 ChatGPT' "$test_dir/restart.log"

printf 'ROLLBACK\n' | env "${common_env[@]}" \
  bash "$repo_dir/platform/macos/codex-rp.sh" rollback > "$test_dir/rollback.log"
cmp -s "$config_file" "$original_config"
[[ ! -e "$mock_keychain" ]]
[[ ! -e "$test_dir/data/active" ]]
find "$test_dir/data/audit" -maxdepth 1 -type d -name 'state-*' | grep -q .

printf 'macOS platform lifecycle: ok\n'
