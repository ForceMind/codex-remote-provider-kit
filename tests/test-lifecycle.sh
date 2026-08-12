#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
IFS= read -r expected_version < "$repo_dir/VERSION"
test_dir=$(mktemp -d)
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

mock_bin="$test_dir/bin"
codex_home="$test_dir/codex-home"
backup_dir="$test_dir/backup"
state_dir="$test_dir/state"
mkdir -p "$mock_bin" "$codex_home" "$backup_dir" "$state_dir"

mock_log="$test_dir/mock.log"
mock_codex="$mock_bin/codex"
cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl:%s\n' "$*" >> "$MOCK_LOG"
case ${1-} in
  is-active)
    [[ ${2-} == "${MOCK_ACTIVE_UNIT:-}" ]]
    ;;
  is-enabled)
    [[ ${2-} == "${MOCK_ENABLED_UNIT:-}" ]]
    printf 'enabled\n'
    ;;
  show)
    if [[ "$*" == *'--value'* ]]; then
      if [[ "$*" == *'ActiveState'* ]]; then
        printf '%s\n' "${MOCK_SHOW_ACTIVE_STATE:-active}"
      elif [[ "$*" == *'Result'* ]]; then
        printf '%s\n' "${MOCK_SHOW_RESULT:-success}"
      fi
    else
      printf 'ActiveState=%s\nSubState=exited\nResult=%s\nUnitFileState=enabled\n' \
        "${MOCK_SHOW_ACTIVE_STATE:-active}" "${MOCK_SHOW_RESULT:-success}"
    fi
    ;;
esac
if [[ -n ${MOCK_FAIL_ENABLE_UNIT:-} \
    && "$*" == "--quiet enable $MOCK_FAIL_ENABLE_UNIT" ]]; then
  exit 1
fi
if [[ -n ${MOCK_FAIL_START_ONCE_UNIT:-} \
    && -n ${MOCK_FAIL_START_ONCE_MARKER:-} \
    && "$*" == "--quiet start $MOCK_FAIL_START_ONCE_UNIT" \
    && ! -e $MOCK_FAIL_START_ONCE_MARKER ]]; then
  : > "$MOCK_FAIL_START_ONCE_MARKER"
  exit 1
fi
EOF
cat > "$mock_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codex:%s\n' "$*" >> "$MOCK_LOG"
case ${1-} in
  --version) printf 'codex-cli test\n' ;;
  login)
    [[ ${2-} == status ]]
    printf 'Logged in using ChatGPT\n'
    ;;
  remote-control)
    [[ ${2-} == stop ]]
    ;;
  exec)
    printf 'unexpected Codex model call\n' >&2
    exit 99
    ;;
esac
EOF
cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl:%s\n' "$*" >> "$MOCK_LOG"
printf '200'
EOF
chmod 755 "$mock_bin/systemctl" "$mock_codex" "$mock_bin/curl"

config_file="$codex_home/config.toml"
profile_file="$codex_home/third_party.config.toml"
state_file="$state_dir/state.env"
secret_file="$test_dir/provider.env"
third_party_unit="$test_dir/codex-remote-provider.service"
official_unit="$test_dir/codex-remote-official.service"
command_file="$test_dir/codex-rp"

cat > "$backup_dir/config.toml" <<'EOF'
model = "official-model"
model_reasoning_effort = "medium"
EOF
cat > "$config_file" <<'EOF'
model_provider = "third_party"
model = "gpt-5.6-sol"
model_reasoning_effort = "high"

[model_providers.third_party]
base_url = "https://gateway.test/v1"
env_key = "TEST_PROVIDER_KEY"
wire_api = "responses"
EOF
cat > "$profile_file" <<'EOF'
model_provider = "third_party"
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
EOF
printf '# original third-party unit\n' > "$backup_dir/codex-remote-provider.service"
printf '# original official unit\n' > "$backup_dir/codex-remote-official.service"
cp "$backup_dir/codex-remote-provider.service" "$third_party_unit"
cp "$backup_dir/codex-remote-official.service" "$official_unit"
printf '#!/usr/bin/env bash\nprintf "original launcher\\n"\n' > "$backup_dir/codex-rp"
chmod 755 "$backup_dir/codex-rp"
printf '# Managed by codex-remote-provider-kit\n' > "$command_file"
printf 'TEST_PROVIDER_KEY="~"\n' > "$secret_file"
chmod 600 "$secret_file"

{
  printf 'PROVIDER_ID=%q\n' third_party
  printf 'ENV_NAME=%q\n' TEST_PROVIDER_KEY
  printf 'BASE_URL=%q\n' https://gateway.test/v1
  printf 'MODEL=%q\n' gpt-5.6-sol
  printf 'REASONING=%q\n' high
  printf 'CODEX_HOME_DIR=%q\n' "$codex_home"
  printf 'CODEX_BIN_PATH=%q\n' "$mock_codex"
  printf 'COMMAND_FILE=%q\n' "$command_file"
  printf 'BACKUP_DIR=%q\n' "$backup_dir"
  printf 'THIRD_PARTY_UNIT_FILE=%q\n' "$third_party_unit"
  printf 'OFFICIAL_UNIT_FILE=%q\n' "$official_unit"
  printf 'THIRD_PARTY_UNIT_EXISTED=%q\n' yes
  printf 'THIRD_PARTY_UNIT_ENABLED=%q\n' no
  printf 'THIRD_PARTY_UNIT_ACTIVE=%q\n' no
  printf 'OFFICIAL_UNIT_EXISTED=%q\n' yes
  printf 'OFFICIAL_UNIT_ENABLED=%q\n' yes
  printf 'OFFICIAL_UNIT_ACTIVE=%q\n' no
  printf 'COMMAND_EXISTED=%q\n' yes
  printf 'LEGACY_ENABLED=%q\n' no
  printf 'LEGACY_ACTIVE=%q\n' no
} > "$state_file"
chmod 600 "$state_file"

common_env=(
  PATH="$mock_bin:$PATH"
  MOCK_LOG="$mock_log"
  CODEX_RP_STATE_FILE="$state_file"
  CODEX_RP_SECRET_FILE="$secret_file"
)
third_party_name=${third_party_unit##*/}
official_name=${official_unit##*/}

printf 'n\n' | env "${common_env[@]}" \
  bash "$repo_dir/use-official.sh" > "$test_dir/use-official-cancel.log"
grep -Fq '操作已取消' "$test_dir/use-official-cancel.log"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "third_party"
PY

printf 'y\n' | env "${common_env[@]}" \
  bash "$repo_dir/use-official.sh" > "$test_dir/use-official.log"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert "model_provider" not in config
assert config["model"] == "official-model"
assert config["model_reasoning_effort"] == "medium"
PY
grep -Fxq '# Managed by codex-remote-provider-kit' "$official_unit"
grep -Fq "systemctl:--quiet disable --now $third_party_name" "$mock_log"
grep -Fq "systemctl:--quiet enable $official_name" "$mock_log"
grep -Fq "systemctl:--quiet start $official_name" "$mock_log"

: > "$mock_log"
env "${common_env[@]}" MOCK_ACTIVE_UNIT="$official_name" \
  MOCK_ENABLED_UNIT="$official_name" \
  bash "$repo_dir/status.sh" --full > "$test_dir/status-official.log"
grep -Fq '当前模式：official' "$test_dir/status-official.log"
grep -Fq "版本：$expected_version" "$test_dir/status-official.log"
grep -Fq '避免意外消耗官方额度' "$test_dir/status-official.log"
if grep -Eq '^(curl:|codex:exec)' "$mock_log"; then
  printf 'official status unexpectedly generated a model request\n' >&2
  exit 1
fi

env "${common_env[@]}" bash "$repo_dir/use-third-party.sh" \
  > "$test_dir/use-third-party.log"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "third_party"
assert config["model"] == "gpt-5.6-sol"
assert config["model_reasoning_effort"] == "high"
PY
grep -Fq 'EnvironmentFile=' "$third_party_unit"

: > "$mock_log"
env "${common_env[@]}" MOCK_ACTIVE_UNIT="$third_party_name" \
  MOCK_ENABLED_UNIT="$third_party_name" \
  bash "$repo_dir/status.sh" > "$test_dir/status-third-party.log"
grep -Fq '当前模式：third-party' "$test_dir/status-third-party.log"
grep -Fq "版本：$expected_version" "$test_dir/status-third-party.log"
grep -Fq 'curl:' "$mock_log"
if grep -Fq 'Authorization: Bearer' "$mock_log"; then
  printf 'secret header was exposed in the curl command line\n' >&2
  exit 1
fi

: > "$mock_log"
transient_marker="$test_dir/transient-start-failed"
printf 'y\n' | env "${common_env[@]}" \
  MOCK_ACTIVE_UNIT="$third_party_name" \
  MOCK_ENABLED_UNIT="$third_party_name" \
  MOCK_FAIL_START_ONCE_UNIT="$official_name" \
  MOCK_FAIL_START_ONCE_MARKER="$transient_marker" \
  bash "$repo_dir/use-official.sh" > "$test_dir/transient-switch.log" 2>&1
[[ -e "$transient_marker" ]]
grep -Fq '正在停止残留 daemon，并重试一次同一模式' \
  "$test_dir/transient-switch.log"
[[ $(grep -Fc "systemctl:--quiet start $official_name" "$mock_log") == 2 ]]
grep -Fq 'Remote 已使用常规/默认 Codex 供应商启动' \
  "$test_dir/transient-switch.log"

env "${common_env[@]}" bash "$repo_dir/use-third-party.sh" \
  > "$test_dir/restore-third-party.log"

: > "$mock_log"
set +e
printf 'y\n' | env "${common_env[@]}" \
  MOCK_ACTIVE_UNIT="$third_party_name" \
  MOCK_ENABLED_UNIT="$third_party_name" \
  MOCK_FAIL_ENABLE_UNIT="$official_name" \
  bash "$repo_dir/use-official.sh" > "$test_dir/switch-failure.log" 2>&1
switch_failure_status=$?
set -e
[[ $switch_failure_status != 0 ]]
grep -Fq '已尝试恢复切换前配置和服务模式' "$test_dir/switch-failure.log"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "third_party"
assert config["model"] == "gpt-5.6-sol"
assert config["model_reasoning_effort"] == "high"
PY
grep -Fq "systemctl:--quiet start $third_party_name" "$mock_log"

: > "$mock_log"
set +e
printf 'y\n' | env "${common_env[@]}" \
  MOCK_ACTIVE_UNIT="$third_party_name" \
  MOCK_ENABLED_UNIT="$third_party_name" \
  MOCK_SHOW_ACTIVE_STATE=failed \
  MOCK_SHOW_RESULT=exit-code \
  bash "$repo_dir/use-official.sh" > "$test_dir/late-switch-failure.log" 2>&1
late_switch_failure_status=$?
set -e
[[ $late_switch_failure_status != 0 ]]
grep -Fq '启动后未保持正常状态' "$test_dir/late-switch-failure.log"
grep -Fq 'journalctl -u' "$test_dir/late-switch-failure.log"
grep -Fq '已尝试恢复切换前配置和服务模式' \
  "$test_dir/late-switch-failure.log"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "third_party"
assert config["model"] == "gpt-5.6-sol"
assert config["model_reasoning_effort"] == "high"
PY
grep -Fq "systemctl:--quiet start $third_party_name" "$mock_log"

set +e
bash "$repo_dir/status.sh" --bad >/dev/null 2>&1
status_code=$?
set -e
[[ $status_code == 2 ]]

printf 'ROLLBACK\n' | env "${common_env[@]}" \
  bash "$repo_dir/rollback.sh" > "$test_dir/rollback.log"
cmp -s "$third_party_unit" "$backup_dir/codex-remote-provider.service"
cmp -s "$official_unit" "$backup_dir/codex-remote-official.service"
cmp -s "$command_file" "$backup_dir/codex-rp"
cmp -s "$config_file" "$backup_dir/config.toml"
[[ ! -e "$secret_file" ]]
[[ ! -e "$state_file" ]]
find "$state_dir/audit" -maxdepth 1 -type f -name 'state-*.env' | grep -q .
grep -Fq '现在可以重新安装' "$test_dir/rollback.log"

collision_dir="$test_dir/collision"
mkdir -p "$collision_dir/backup"
collision_state="$collision_dir/state.env"
collision_official_unit="$collision_dir/codex-remote-official.service"
collision_third_party_unit="$collision_dir/codex-remote-provider.service"
collision_command="$collision_dir/codex-rp"
printf '# external official unit\n' > "$collision_official_unit"
cp "$collision_official_unit" "$collision_dir/original-official-unit"
{
  printf 'PROVIDER_ID=%q\n' third_party
  printf 'MODEL=%q\n' gpt-5.6-sol
  printf 'REASONING=%q\n' high
  printf 'CODEX_BIN_PATH=%q\n' "$mock_codex"
  printf 'COMMAND_FILE=%q\n' "$collision_command"
  printf 'BACKUP_DIR=%q\n' "$collision_dir/backup"
  printf 'THIRD_PARTY_UNIT_FILE=%q\n' "$collision_third_party_unit"
  printf 'OFFICIAL_UNIT_FILE=%q\n' "$collision_official_unit"
} > "$collision_state"
env \
  PATH="$mock_bin:$PATH" \
  MOCK_LOG="$mock_log" \
  MOCK_ACTIVE_UNIT=codex-remote-official.service \
  MOCK_ENABLED_UNIT=codex-remote-official.service \
  CODEX_RP_STATE_FILE="$collision_state" \
  CODEX_RP_SECRET_FILE="$collision_dir/provider.env" \
  bash "$repo_dir/refresh-units.sh" > "$test_dir/collision.log"
cmp -s "$collision_dir/backup/codex-remote-official.service" \
  "$collision_dir/original-official-unit"
grep -Fxq 'OFFICIAL_UNIT_EXISTED=yes' "$collision_state"
grep -Fxq 'OFFICIAL_UNIT_ENABLED=yes' "$collision_state"
grep -Fxq 'OFFICIAL_UNIT_ACTIVE=yes' "$collision_state"

printf 'mode switching and rollback lifecycle: ok\n'
