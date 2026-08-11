#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"
test_dir=$(mktemp -d)
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT
mock_bin="$test_dir/bin"
codex_home="$test_dir/codex-home"
mkdir -p "$mock_bin" "$codex_home"
cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -z ${MOCK_LOG:-} ]] || printf 'systemctl:%s\n' "$*" >> "$MOCK_LOG"
if [[ -n ${MOCK_FAIL_RESTART_UNIT:-} \
    && "$*" == "restart $MOCK_FAIL_RESTART_UNIT" ]]; then
  exit 1
fi
case ${1-} in
  is-active) [[ ${2-} == "${MOCK_ACTIVE_UNIT:-}" ]]; exit ;;
  is-enabled)
    [[ ${2-} == "${MOCK_ENABLED_UNIT:-}" ]]
    printf 'enabled\n'
    exit
    ;;
  show) printf 'ActiveState=active\nSubState=exited\nResult=success\nUnitFileState=enabled\n' ;;
esac
exit 0
EOF
chmod 755 "$mock_bin/systemctl"
real_cp=$(command -v cp)
cat > "$mock_bin/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n ${MOCK_CP_COPY_THEN_FAIL_SOURCE:-} ]]; then
  for argument in "$@"; do
    if [[ "$argument" == "$MOCK_CP_COPY_THEN_FAIL_SOURCE" ]]; then
      "$REAL_CP" "$@"
      exit 1
    fi
  done
fi
exec "$REAL_CP" "$@"
EOF
chmod 755 "$mock_bin/cp"
real_rm=$(command -v rm)
cat > "$mock_bin/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n ${MOCK_RM_FAIL_TARGET:-} ]]; then
  for argument in "$@"; do
    [[ "$argument" != "$MOCK_RM_FAIL_TARGET" ]] || exit 1
  done
fi
exec "$REAL_RM" "$@"
EOF
chmod 755 "$mock_bin/rm"

state_file="$test_dir/state.env"
secret_file="$test_dir/provider.env"
third_party_unit="$test_dir/codex-remote-provider.service"
official_unit="$test_dir/codex-remote-official.service"
command_file="$test_dir/codex-rp"
config_file="$codex_home/config.toml"
profile_file="$codex_home/third_party.config.toml"
mock_log="$test_dir/systemctl.log"
third_party_name=${third_party_unit##*/}
official_name=${official_unit##*/}
cat > "$config_file" <<'EOF'
model_provider = "stable_session"
model = "official-model"
model_reasoning_effort = "low"

# BEGIN codex-remote-provider-kit:stable_session
[model_providers.stable_session]
name = "stable_session"
base_url = "https://chatgpt.com/backend-api/codex"
requires_openai_auth = true
wire_api = "responses"
# END codex-remote-provider-kit:stable_session

# BEGIN codex-remote-provider-kit:third_party
[model_providers.third_party]
name = "third_party"
base_url = "https://old.test/v1"
env_key = "TEST_KEY"
wire_api = "responses"
# END codex-remote-provider-kit:third_party
EOF
printf 'model = "old-model"\nmodel_provider = "third_party"\nmodel_reasoning_effort = "high"\n' > "$profile_file"
printf 'TEST_KEY="old_key"\n' > "$secret_file"
chmod 600 "$secret_file"
printf '# Managed by codex-remote-provider-kit\n' > "$third_party_unit"
printf '# Managed by codex-remote-provider-kit\n' > "$official_unit"
printf '# Managed by codex-remote-provider-kit\n' > "$command_file"
mkdir -p "$test_dir/backup"
printf 'model = "official-model"\nmodel_reasoning_effort = "low"\n' > "$test_dir/backup/config.toml"
{
  printf 'PROVIDER_ID=%q\n' third_party
  printf 'SESSION_PROVIDER_ID=%q\n' stable_session
  printf 'ENV_NAME=%q\n' TEST_KEY
  printf 'BASE_URL=%q\n' https://old.test/v1
  printf 'MODEL=%q\n' old-model
  printf 'REASONING=%q\n' high
  printf 'CODEX_HOME_DIR=%q\n' "$codex_home"
  printf 'CODEX_BIN_PATH=%q\n' /usr/bin/true
  printf 'COMMAND_FILE=%q\n' "$command_file"
  printf 'BACKUP_DIR=%q\n' "$test_dir/backup"
  printf 'THIRD_PARTY_UNIT_FILE=%q\n' "$third_party_unit"
  printf 'OFFICIAL_UNIT_FILE=%q\n' "$official_unit"
} > "$state_file"
chmod 600 "$state_file"
common_env=(
  PATH="$mock_bin:$PATH"
  REAL_CP="$real_cp"
  REAL_RM="$real_rm"
  MOCK_LOG="$mock_log"
  MOCK_ACTIVE_UNIT="$official_name"
  MOCK_ENABLED_UNIT="$official_name"
  CODEX_RP_STATE_FILE="$state_file"
  CODEX_RP_SECRET_FILE="$secret_file"
)
providers_dir="$test_dir/provider-records"
provider_secrets_dir="$test_dir/provider-secrets"
common_env+=(
  CODEX_RP_PROVIDERS_DIR="$providers_dir"
  CODEX_RP_PROVIDER_SECRETS_DIR="$provider_secrets_dir"
)

mkdir -p "$providers_dir" "$provider_secrets_dir"
chmod 700 "$providers_dir" "$provider_secrets_dir"
write_provider_record "$providers_dir/third_party.env" third_party TEST_KEY \
  https://old.test/v1 old-model high
cp -p "$secret_file" "$provider_secrets_dir/third_party.env"
snapshot_tmp="$test_dir/snapshot-tmp"
mkdir -p "$snapshot_tmp"
cp -p "$state_file" "$test_dir/pre-snapshot-state"
cp -p "$config_file" "$test_dir/pre-snapshot-config"
cp -p "$secret_file" "$test_dir/pre-snapshot-active-secret"
cp -p "$profile_file" "$test_dir/pre-snapshot-profile"
cp -p "$providers_dir/third_party.env" "$test_dir/pre-snapshot-record"
cp -p "$provider_secrets_dir/third_party.env" "$test_dir/pre-snapshot-stored-secret"
set +e
env "${common_env[@]}" \
  TMPDIR="$snapshot_tmp" \
  MOCK_CP_COPY_THEN_FAIL_SOURCE="$provider_secrets_dir/third_party.env" \
  bash "$repo_dir/reconfigure.sh" </dev/null \
  > "$test_dir/snapshot-copy-failure.log" 2>&1
snapshot_copy_failure_status=$?
set -e
[[ $snapshot_copy_failure_status != 0 ]]
cmp -s "$state_file" "$test_dir/pre-snapshot-state"
cmp -s "$config_file" "$test_dir/pre-snapshot-config"
cmp -s "$secret_file" "$test_dir/pre-snapshot-active-secret"
cmp -s "$profile_file" "$test_dir/pre-snapshot-profile"
cmp -s "$providers_dir/third_party.env" "$test_dir/pre-snapshot-record"
cmp -s "$provider_secrets_dir/third_party.env" "$test_dir/pre-snapshot-stored-secret"
if find "$snapshot_tmp" -mindepth 1 -print -quit | grep -q .; then
  printf 'failed snapshot left a temporary directory containing copied data\n' >&2
  exit 1
fi
rm -rf "$providers_dir" "$provider_secrets_dir"

cp -p "$state_file" "$test_dir/pre-input-state"
cp -p "$config_file" "$test_dir/pre-input-config"
set +e
env "${common_env[@]}" bash "$repo_dir/reconfigure.sh" \
  </dev/null > "$test_dir/input-eof.log" 2>&1
input_eof_status=$?
set -e
[[ $input_eof_status != 0 ]]
cmp -s "$state_file" "$test_dir/pre-input-state"
cmp -s "$config_file" "$test_dir/pre-input-config"
[[ ! -e "$providers_dir" ]]
[[ ! -e "$provider_secrets_dir" ]]

cp -p "$state_file" "$test_dir/pre-cleanup-state"
cp -p "$config_file" "$test_dir/pre-cleanup-config"
cp -p "$secret_file" "$test_dir/pre-cleanup-secret"
cp -p "$profile_file" "$test_dir/pre-cleanup-profile"
cp -p "$third_party_unit" "$test_dir/pre-cleanup-third-party-unit"
cp -p "$official_unit" "$test_dir/pre-cleanup-official-unit"
cp -p "$command_file" "$test_dir/pre-cleanup-command"
set +e
printf '\n\n\n\n' | env "${common_env[@]}" \
  MOCK_RM_FAIL_TARGET="$profile_file" \
  bash "$repo_dir/reconfigure.sh" > "$test_dir/legacy-cleanup-failure.log" 2>&1
legacy_cleanup_failure_status=$?
set -e
[[ $legacy_cleanup_failure_status != 0 ]]
grep -Fq '更新失败；已恢复修改前的配置、密钥和服务模式' \
  "$test_dir/legacy-cleanup-failure.log"
cmp -s "$state_file" "$test_dir/pre-cleanup-state"
cmp -s "$config_file" "$test_dir/pre-cleanup-config"
cmp -s "$secret_file" "$test_dir/pre-cleanup-secret"
cmp -s "$profile_file" "$test_dir/pre-cleanup-profile"
cmp -s "$third_party_unit" "$test_dir/pre-cleanup-third-party-unit"
cmp -s "$official_unit" "$test_dir/pre-cleanup-official-unit"
cmp -s "$command_file" "$test_dir/pre-cleanup-command"
[[ ! -e "$providers_dir" ]]
[[ ! -e "$provider_secrets_dir" ]]

new_provider_id=$(provider_id_from_base_url https://new.test/v1)
new_env_name=$(provider_env_name_from_id "$new_provider_id")
old_provider_id=$(provider_id_from_base_url https://old.test/v1)
old_env_name=$(provider_env_name_from_id "$old_provider_id")

printf '\n\n\n\n' | env "${common_env[@]}" \
  bash "$repo_dir/reconfigure.sh" > "$test_dir/migrate.log"
# shellcheck disable=SC1090
source "$state_file"
[[ "$PROVIDER_ID" == "$old_provider_id" && "$BASE_URL" == https://old.test/v1 ]]
[[ "$SESSION_PROVIDER_ID" == stable_session ]]
grep -Fxq "$old_env_name=\"old_key\"" "$secret_file"
[[ ! -e "$providers_dir/third_party.env" ]]
[[ ! -e "$provider_secrets_dir/third_party.env" ]]
[[ ! -e "$profile_file" ]]
[[ -e "$providers_dir/$old_provider_id.env" ]]
[[ -e "$provider_secrets_dir/$old_provider_id.env" ]]
python3 - "$config_file" "$old_provider_id" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "stable_session"
assert config["model"] == "official-model"
assert config["model_reasoning_effort"] == "low"
session = config["model_providers"]["stable_session"]
assert session["base_url"] == "https://chatgpt.com/backend-api/codex"
assert session["requires_openai_auth"] is True
assert "env_key" not in session
assert config["model_providers"][sys.argv[2]]["base_url"] == "https://old.test/v1"
PY

foreign_record="$providers_dir/$new_provider_id.env"
printf 'foreign provider record\n' > "$foreign_record"
chmod 600 "$foreign_record"
set +e
printf 'https://new.test/v1\n' | env "${common_env[@]}" \
  bash "$repo_dir/reconfigure.sh" > "$test_dir/foreign-record.log" 2>&1
foreign_record_status=$?
set -e
[[ $foreign_record_status != 0 ]]
grep -Fq '新 Provider ID 与非受管文件冲突' "$test_dir/foreign-record.log"
grep -Fxq 'foreign provider record' "$foreign_record"
rm "$foreign_record"

foreign_profile_target="$test_dir/foreign-profile-target"
foreign_profile_link="$codex_home/$new_provider_id.config.toml"
printf 'foreign profile target\n' > "$foreign_profile_target"
ln -s "$foreign_profile_target" "$foreign_profile_link"
set +e
printf 'https://new.test/v1\n' | env "${common_env[@]}" \
  bash "$repo_dir/reconfigure.sh" > "$test_dir/foreign-profile.log" 2>&1
foreign_profile_status=$?
set -e
[[ $foreign_profile_status != 0 ]]
grep -Fq '新 Provider ID 与非受管文件冲突' "$test_dir/foreign-profile.log"
[[ -L "$foreign_profile_link" ]]
grep -Fxq 'foreign profile target' "$foreign_profile_target"
rm "$foreign_profile_link"

printf 'https://new.test/v1\nnew-model\nmedium\nnew_key==\n' | env "${common_env[@]}" \
  bash "$repo_dir/reconfigure.sh" > "$test_dir/reconfigure.log"
python3 - "$config_file" "$new_provider_id" "$old_provider_id" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "stable_session"
assert config["model"] == "official-model"
assert config["model_reasoning_effort"] == "low"
old_id = sys.argv[3]
assert "third_party" not in config["model_providers"]
assert config["model_providers"][old_id]["base_url"] == "https://old.test/v1"
assert config["model_providers"][sys.argv[2]]["base_url"] == "https://new.test/v1"
session = config["model_providers"]["stable_session"]
assert session["base_url"] == "https://chatgpt.com/backend-api/codex"
assert session["requires_openai_auth"] is True
assert "env_key" not in session
PY
# shellcheck disable=SC1090
source "$state_file"
[[ "$PROVIDER_ID" == "$new_provider_id" ]]
[[ "$SESSION_PROVIDER_ID" == stable_session ]]
[[ "$BASE_URL" == https://new.test/v1 && "$MODEL" == new-model && "$REASONING" == medium ]]
grep -Fxq "$new_env_name=\"new_key==\"" "$secret_file"
grep -Fxq "$old_env_name=\"old_key\"" \
  "$provider_secrets_dir/$old_provider_id.env"
grep -Fxq "$new_env_name=\"new_key==\"" \
  "$provider_secrets_dir/$new_provider_id.env"
[[ -f "$providers_dir/$old_provider_id.env" ]]
[[ -f "$providers_dir/$new_provider_id.env" ]]
grep -Fq 'https://new.test/v1 / new-model / medium' "$test_dir/reconfigure.log"

printf 'rotated_key==\n' | env "${common_env[@]}" \
  bash "$repo_dir/reconfigure.sh" --key-only > "$test_dir/rotate.log"
grep -Fxq "$new_env_name=\"rotated_key==\"" "$secret_file"
grep -Fq '内容已隐藏' "$test_dir/rotate.log"
if grep -Fq 'rotated_key==' "$test_dir/rotate.log"; then
  printf 'rotated key was printed\n' >&2
  exit 1
fi

env "${common_env[@]}" bash "$repo_dir/use-third-party.sh" "$old_provider_id" \
  > "$test_dir/switch-old.log"
# shellcheck disable=SC1090
source "$state_file"
[[ "$PROVIDER_ID" == "$old_provider_id" && "$BASE_URL" == https://old.test/v1 ]]
[[ "$SESSION_PROVIDER_ID" == stable_session ]]
grep -Fxq "$old_env_name=\"old_key\"" "$secret_file"
python3 - "$config_file" "$old_provider_id" "$old_env_name" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "stable_session"
assert config["model"] == "old-model"
session = config["model_providers"]["stable_session"]
assert session["base_url"] == "https://old.test/v1"
assert session["env_key"] == sys.argv[3]
assert "requires_openai_auth" not in session
PY

env "${common_env[@]}" bash "$repo_dir/use-third-party.sh" "$new_provider_id" \
  > "$test_dir/switch-new.log"
# shellcheck disable=SC1090
source "$state_file"
[[ "$PROVIDER_ID" == "$new_provider_id" && "$BASE_URL" == https://new.test/v1 ]]
[[ "$SESSION_PROVIDER_ID" == stable_session ]]
grep -Fxq "$new_env_name=\"rotated_key==\"" "$secret_file"
grep -Fq "已切换到：$new_provider_id" "$test_dir/switch-new.log"
python3 - "$config_file" "$new_env_name" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "stable_session"
assert config["model"] == "new-model"
assert config["model_reasoning_effort"] == "medium"
session = config["model_providers"]["stable_session"]
assert session["base_url"] == "https://new.test/v1"
assert session["env_key"] == sys.argv[2]
assert "requires_openai_auth" not in session
PY

printf '\n\n\n\n' | env "${common_env[@]}" \
  MOCK_ACTIVE_UNIT= \
  MOCK_ENABLED_UNIT="$third_party_name" \
  bash "$repo_dir/reconfigure.sh" > "$test_dir/stopped-third-party.log"
grep -Fq '第三方 Remote 当前已停止' "$test_dir/stopped-third-party.log"
python3 - "$config_file" "$new_env_name" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "stable_session"
session = config["model_providers"]["stable_session"]
assert session["base_url"] == "https://new.test/v1"
assert session["env_key"] == sys.argv[2]
assert "requires_openai_auth" not in session
PY

failure_snapshot="$test_dir/failure-snapshot"
mkdir -p "$failure_snapshot"
cp -p "$state_file" "$failure_snapshot/state"
cp -p "$secret_file" "$failure_snapshot/active-secret"
cp -p "$config_file" "$failure_snapshot/config"
cp -p "$third_party_unit" "$failure_snapshot/third-party-unit"
cp -p "$official_unit" "$failure_snapshot/official-unit"
cp -p "$command_file" "$failure_snapshot/command"
cp -p "$providers_dir/$new_provider_id.env" "$failure_snapshot/provider-record"
cp -p "$provider_secrets_dir/$new_provider_id.env" "$failure_snapshot/provider-secret"
cp -p "$codex_home/$new_provider_id.config.toml" "$failure_snapshot/profile"

assert_failure_rollback() {
  cmp -s "$state_file" "$failure_snapshot/state"
  cmp -s "$secret_file" "$failure_snapshot/active-secret"
  cmp -s "$config_file" "$failure_snapshot/config"
  cmp -s "$third_party_unit" "$failure_snapshot/third-party-unit"
  cmp -s "$official_unit" "$failure_snapshot/official-unit"
  cmp -s "$command_file" "$failure_snapshot/command"
  cmp -s "$providers_dir/$new_provider_id.env" "$failure_snapshot/provider-record"
  cmp -s "$provider_secrets_dir/$new_provider_id.env" "$failure_snapshot/provider-secret"
  cmp -s "$codex_home/$new_provider_id.config.toml" "$failure_snapshot/profile"
}

: > "$mock_log"
set +e
printf '\nrestart-failure-model\nhigh\n\n' | env "${common_env[@]}" \
  MOCK_ACTIVE_UNIT="$third_party_name" \
  MOCK_ENABLED_UNIT="$third_party_name" \
  MOCK_FAIL_RESTART_UNIT="$third_party_name" \
  bash "$repo_dir/reconfigure.sh" > "$test_dir/restart-failure.log" 2>&1
restart_failure_status=$?
set -e
[[ $restart_failure_status != 0 ]]
grep -Fq '更新失败；已恢复修改前的配置、密钥和服务模式' \
  "$test_dir/restart-failure.log"
grep -Fq "systemctl:start $third_party_name" "$mock_log"
assert_failure_rollback

: > "$mock_log"
set +e
printf '\nstatus-failure-model\nhigh\n\n' | env "${common_env[@]}" \
  MOCK_ACTIVE_UNIT="$third_party_name" \
  MOCK_ENABLED_UNIT="$third_party_name" \
  bash "$repo_dir/reconfigure.sh" > "$test_dir/status-failure.log" 2>&1
status_failure_status=$?
set -e
[[ $status_failure_status != 0 ]]
grep -Fq '更新失败；已恢复修改前的配置、密钥和服务模式' \
  "$test_dir/status-failure.log"
grep -Fq "systemctl:restart $third_party_name" "$mock_log"
grep -Fq "systemctl:start $third_party_name" "$mock_log"
assert_failure_rollback

# A successful legacy-ID migration must still retain enough historical
# ownership information for a complete rollback.
set_state_variable "$state_file" CODEX_BIN_PATH /usr/bin/true
printf 'foreign legacy profile\n' > "$profile_file"
set +e
printf 'ROLLBACK\n' | env "${common_env[@]}" \
  bash "$repo_dir/rollback.sh" > "$test_dir/migrated-profile-conflict.log" 2>&1
migrated_profile_conflict_status=$?
set -e
[[ $migrated_profile_conflict_status != 0 ]]
grep -Fq '旧 profile 路径被其他文件占用' \
  "$test_dir/migrated-profile-conflict.log"
grep -Fxq 'foreign legacy profile' "$profile_file"
[[ -f "$state_file" ]]
rm "$profile_file"
printf 'ROLLBACK\n' | env "${common_env[@]}" \
  bash "$repo_dir/rollback.sh" > "$test_dir/migrated-id-rollback.log"
[[ ! -e "$state_file" ]]
[[ ! -e "$secret_file" ]]
[[ ! -e "$providers_dir/$old_provider_id.env" ]]
[[ ! -e "$providers_dir/$new_provider_id.env" ]]
[[ ! -e "$provider_secrets_dir/$old_provider_id.env" ]]
[[ ! -e "$provider_secrets_dir/$new_provider_id.env" ]]
[[ ! -e "$codex_home/$old_provider_id.config.toml" ]]
[[ ! -e "$codex_home/$new_provider_id.config.toml" ]]
[[ ! -e "$profile_file" ]]
cmp -s "$config_file" "$test_dir/backup/config.toml"
grep -Fq '回滚完成' "$test_dir/migrated-id-rollback.log"

printf 'provider reconfiguration and key rotation: ok\n'
