#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d)
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

mock_bin="$test_dir/bin"
mock_log="$test_dir/mock.log"
mkdir -p "$mock_bin"
cat > "$mock_bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codex:%s\n' "$*" >> "$MOCK_LOG"
if [[ ${1-} == login && ${2-} == status ]]; then
  printf 'Logged in using ChatGPT\n' >&2
fi
EOF
cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl:%s\n' "$*" >> "$MOCK_LOG"
case ${1-} in
  is-enabled|is-active) exit 1 ;;
  show)
    if [[ "$*" == *'--value'* ]]; then
      if [[ "$*" == *'ActiveState'* ]]; then
        printf '%s\n' "${MOCK_SHOW_ACTIVE_STATE:-active}"
      elif [[ "$*" == *'Result'* ]]; then
        printf '%s\n' "${MOCK_SHOW_RESULT:-success}"
      fi
    else
      printf 'ActiveState=%s\nSubState=exited\nResult=%s\n' \
        "${MOCK_SHOW_ACTIVE_STATE:-active}" "${MOCK_SHOW_RESULT:-success}"
    fi
    ;;
esac
if [[ -n ${MOCK_FAIL_UNIT:-} && "$*" == "--quiet start $MOCK_FAIL_UNIT" ]]; then
  exit 1
fi
EOF
chmod 755 "$mock_bin/codex" "$mock_bin/systemctl"

run_installer() {
  local fixture=${1:?fixture directory required}
  shift
  env \
    PATH="$mock_bin:$PATH" \
    MOCK_LOG="$mock_log" \
    THIRD_PARTY_API_KEY='test_token' \
    CODEX_RP_SECRET_FILE="$fixture/provider.env" \
    CODEX_RP_STATE_FILE="$fixture/state.env" \
    CODEX_RP_THIRD_PARTY_UNIT_FILE="$fixture/codex-remote-provider.service" \
    CODEX_RP_OFFICIAL_UNIT_FILE="$fixture/codex-remote-official.service" \
    CODEX_RP_COMMAND_FILE="$fixture/codex-rp" \
    "$@" \
    bash "$repo_dir/install-provider.sh" \
      --base-url https://gateway.test/v1 \
      --model gpt-5.6-sol \
      --provider-id third_party \
      --codex-home "$fixture/codex-home" \
      --codex-bin "$mock_bin/codex"
}

success_dir="$test_dir/success"
mkdir -p "$success_dir/codex-home"
run_installer "$success_dir" > "$test_dir/success.log"
[[ -s "$success_dir/state.env" ]]
[[ $(stat -c '%a' "$success_dir/state.env") == 600 ]]
[[ $(stat -c '%a' "$success_dir/provider.env") == 600 ]]
grep -Fxq 'THIRD_PARTY_API_KEY="test_token"' "$success_dir/provider.env"
grep -Fxq '# Managed by codex-remote-provider-kit' \
  "$success_dir/codex-remote-provider.service"
grep -Fxq '# Managed by codex-remote-provider-kit' \
  "$success_dir/codex-remote-official.service"
python3 - "$success_dir/codex-home/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "third_party"
assert config["model"] == "gpt-5.6-sol"
assert config["model_reasoning_effort"] == "high"
assert config["model_providers"]["third_party"]["base_url"] == "https://gateway.test/v1"
PY

set +e
run_installer "$success_dir" > "$test_dir/reinstall.log" 2>&1
reinstall_status=$?
set -e
[[ $reinstall_status != 0 ]]
grep -Fq '检测到现有安装状态' "$test_dir/reinstall.log"

failure_dir="$test_dir/failure"
mkdir -p "$failure_dir/codex-home"
printf 'model = "original-model"\n' > "$failure_dir/codex-home/config.toml"
printf '# original third-party unit\n' > "$failure_dir/codex-remote-provider.service"
printf '# original official unit\n' > "$failure_dir/codex-remote-official.service"
printf '#!/usr/bin/env bash\n# Managed by codex-remote-provider-kit\nprintf "original\\n"\n' \
  > "$failure_dir/codex-rp"
chmod 755 "$failure_dir/codex-rp"
cp "$failure_dir/codex-home/config.toml" "$failure_dir/original-config"
cp "$failure_dir/codex-remote-provider.service" "$failure_dir/original-third-party-unit"
cp "$failure_dir/codex-remote-official.service" "$failure_dir/original-official-unit"
cp "$failure_dir/codex-rp" "$failure_dir/original-command"

set +e
run_installer "$failure_dir" \
  MOCK_FAIL_UNIT=codex-remote-provider.service \
  > "$test_dir/failure.log" 2>&1
failure_status=$?
set -e
[[ $failure_status != 0 ]]
grep -Fq '正在恢复安装前状态' "$test_dir/failure.log"
cmp -s "$failure_dir/codex-home/config.toml" "$failure_dir/original-config"
cmp -s "$failure_dir/codex-remote-provider.service" \
  "$failure_dir/original-third-party-unit"
cmp -s "$failure_dir/codex-remote-official.service" \
  "$failure_dir/original-official-unit"
cmp -s "$failure_dir/codex-rp" "$failure_dir/original-command"
[[ ! -e "$failure_dir/codex-home/third_party.config.toml" ]]
[[ ! -e "$failure_dir/provider.env" ]]
[[ ! -e "$failure_dir/state.env" ]]

late_failure_dir="$test_dir/late-failure"
mkdir -p "$late_failure_dir/codex-home"
printf 'model = "original-model"\n' > "$late_failure_dir/codex-home/config.toml"
cp "$late_failure_dir/codex-home/config.toml" "$late_failure_dir/original-config"

set +e
run_installer "$late_failure_dir" \
  MOCK_SHOW_ACTIVE_STATE=failed \
  MOCK_SHOW_RESULT=exit-code \
  > "$test_dir/late-failure.log" 2>&1
late_failure_status=$?
set -e
[[ $late_failure_status != 0 ]]
grep -Fq '启动后未保持正常状态' "$test_dir/late-failure.log"
grep -Fq '正在恢复安装前状态' "$test_dir/late-failure.log"
cmp -s "$late_failure_dir/codex-home/config.toml" \
  "$late_failure_dir/original-config"
[[ ! -e "$late_failure_dir/codex-home/third_party.config.toml" ]]
[[ ! -e "$late_failure_dir/provider.env" ]]
[[ ! -e "$late_failure_dir/state.env" ]]

set +e
THIRD_PARTY_API_KEY='test_token' bash "$repo_dir/install-provider.sh" \
  --base-url http://gateway.test/v1 \
  --model gpt-5.6-sol \
  --codex-bin "$mock_bin/codex" > "$test_dir/http.log" 2>&1
http_status=$?
set -e
[[ $http_status != 0 ]]
grep -Fq '默认必须使用 HTTPS' "$test_dir/http.log"

set +e
THIRD_PARTY_API_KEY='test_token' bash "$repo_dir/install-provider.sh" \
  --base-url https://user:password@gateway.test/v1 \
  --model gpt-5.6-sol \
  --codex-bin "$mock_bin/codex" > "$test_dir/userinfo.log" 2>&1
userinfo_status=$?
set -e
[[ $userinfo_status != 0 ]]
grep -Fq '不能包含用户名、密码' "$test_dir/userinfo.log"

printf 'provider installation and transaction rollback: ok\n'
