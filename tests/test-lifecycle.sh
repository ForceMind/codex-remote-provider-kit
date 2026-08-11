#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
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
if [[ ${1-} == daemon-reload && ${MOCK_FAIL_DAEMON_ONCE:-no} == yes ]]; then
  daemon_count=0
  [[ ! -f ${MOCK_DAEMON_COUNT_FILE:-} ]] \
    || daemon_count=$(< "$MOCK_DAEMON_COUNT_FILE")
  daemon_count=$((daemon_count + 1))
  printf '%s\n' "$daemon_count" > "$MOCK_DAEMON_COUNT_FILE"
  ((daemon_count > 1)) || exit 1
fi
case ${1-} in
  is-active)
    [[ ${2-} == "${MOCK_ACTIVE_UNIT:-}" ]]
    ;;
  is-enabled)
    [[ ${2-} == "${MOCK_ENABLED_UNIT:-}" ]]
    printf 'enabled\n'
    ;;
  show)
    printf 'ActiveState=active\nSubState=exited\nResult=success\nUnitFileState=enabled\n'
    ;;
esac
if [[ -n ${MOCK_FAIL_ENABLE_UNIT:-} \
    && "$*" == "--quiet enable $MOCK_FAIL_ENABLE_UNIT" ]]; then
  exit 1
fi
if [[ -n ${MOCK_FAIL_DISABLE_UNIT:-} \
    && "$*" == "--quiet disable --now $MOCK_FAIL_DISABLE_UNIT" ]]; then
  exit 1
fi
if [[ -n ${MOCK_FAIL_RESTART_UNIT:-} \
    && "$*" == "restart $MOCK_FAIL_RESTART_UNIT" ]]; then
  exit 1
fi
if [[ -n ${MOCK_FAIL_START_UNIT:-} \
    && "$*" == "start $MOCK_FAIL_START_UNIT" ]]; then
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
model_provider = "stable_session"
model = "gpt-5.6-sol"
model_reasoning_effort = "high"

# BEGIN codex-remote-provider-kit:stable_session
[model_providers.stable_session]
name = "stable_session"
base_url = "https://gateway.test/v1"
env_key = "TEST_PROVIDER_KEY"
wire_api = "responses"
# END codex-remote-provider-kit:stable_session
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
printf '# Managed by codex-remote-provider-kit\n# installed third-party unit\n' \
  > "$third_party_unit"
printf '# Managed by codex-remote-provider-kit\n# installed official unit\n' \
  > "$official_unit"
printf '#!/usr/bin/env bash\nprintf "original launcher\\n"\n' > "$backup_dir/codex-rp"
chmod 755 "$backup_dir/codex-rp"
printf '# Managed by codex-remote-provider-kit\n' > "$command_file"
printf 'TEST_PROVIDER_KEY="~"\n' > "$secret_file"
chmod 600 "$secret_file"

{
  printf 'PROVIDER_ID=%q\n' third_party
  printf 'SESSION_PROVIDER_ID=%q\n' stable_session
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
assert config["model_provider"] == "stable_session"
PY

printf 'y\n' | env "${common_env[@]}" \
  bash "$repo_dir/use-official.sh" > "$test_dir/use-official.log"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "stable_session"
assert config["model"] == "official-model"
assert config["model_reasoning_effort"] == "medium"
provider = config["model_providers"]["stable_session"]
assert provider["base_url"] == "https://chatgpt.com/backend-api/codex"
assert provider["requires_openai_auth"] is True
assert provider["wire_api"] == "responses"
assert "env_key" not in provider
PY
grep -Fxq '# Managed by codex-remote-provider-kit' "$official_unit"
grep -Fq "systemctl:--quiet disable --now $third_party_name" "$mock_log"
grep -Fq "systemctl:--quiet enable $official_name" "$mock_log"
grep -Fq "systemctl:restart $official_name" "$mock_log"

: > "$mock_log"
env "${common_env[@]}" MOCK_ACTIVE_UNIT="$official_name" \
  MOCK_ENABLED_UNIT="$official_name" \
  bash "$repo_dir/status.sh" --full > "$test_dir/status-official.log"
grep -Fq '当前模式：official' "$test_dir/status-official.log"
grep -Fq '避免意外消耗官方额度' "$test_dir/status-official.log"
if grep -Eq '^(curl:|codex:exec)' "$mock_log"; then
  printf 'official status unexpectedly generated a model request\n' >&2
  exit 1
fi

chmod 644 "$secret_file"
set +e
env "${common_env[@]}" MOCK_ACTIVE_UNIT="$official_name" \
  MOCK_ENABLED_UNIT="$official_name" \
  bash "$repo_dir/status.sh" > "$test_dir/status-permission-failure.log" 2>&1
permission_failure_status=$?
set -e
[[ $permission_failure_status != 0 ]]
grep -Fq '活动密钥文件必须由 root 拥有且权限为 0600' \
  "$test_dir/status-permission-failure.log"
chmod 600 "$secret_file"

env "${common_env[@]}" bash "$repo_dir/use-third-party.sh" \
  > "$test_dir/use-third-party.log"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "stable_session"
assert config["model"] == "gpt-5.6-sol"
assert config["model_reasoning_effort"] == "high"
provider = config["model_providers"]["stable_session"]
assert provider["base_url"] == "https://gateway.test/v1"
assert provider["env_key"] == "TEST_PROVIDER_KEY"
assert provider["wire_api"] == "responses"
assert "requires_openai_auth" not in provider
PY
grep -Fq 'EnvironmentFile=' "$third_party_unit"

: > "$mock_log"
env "${common_env[@]}" MOCK_ACTIVE_UNIT="$third_party_name" \
  MOCK_ENABLED_UNIT="$third_party_name" \
  bash "$repo_dir/status.sh" > "$test_dir/status-third-party.log"
grep -Fq '当前模式：third-party' "$test_dir/status-third-party.log"
grep -Fq 'curl:' "$mock_log"
if grep -Fq 'Authorization: Bearer' "$mock_log"; then
  printf 'secret header was exposed in the curl command line\n' >&2
  exit 1
fi

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
grep -Fq '切换失败；已恢复切换前配置和服务模式' "$test_dir/switch-failure.log"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "stable_session"
assert config["model"] == "gpt-5.6-sol"
assert config["model_reasoning_effort"] == "high"
provider = config["model_providers"]["stable_session"]
assert provider["base_url"] == "https://gateway.test/v1"
assert provider["env_key"] == "TEST_PROVIDER_KEY"
assert "requires_openai_auth" not in provider
PY
grep -Fq "systemctl:start $third_party_name" "$mock_log"

: > "$mock_log"
set +e
printf 'y\n' | env "${common_env[@]}" \
  MOCK_ACTIVE_UNIT="$third_party_name" \
  MOCK_ENABLED_UNIT="$third_party_name" \
  MOCK_FAIL_ENABLE_UNIT="$official_name" \
  MOCK_FAIL_START_UNIT="$third_party_name" \
  bash "$repo_dir/use-official.sh" \
  > "$test_dir/incomplete-switch-recovery.log" 2>&1
incomplete_switch_recovery_status=$?
set -e
[[ $incomplete_switch_recovery_status != 0 ]]
grep -Fq "自动恢复失败：无法重新启动 $third_party_name" \
  "$test_dir/incomplete-switch-recovery.log"
grep -Fq '切换失败，且自动恢复不完整' \
  "$test_dir/incomplete-switch-recovery.log"
grep -Fq '自动恢复备份保留在 root-only 临时目录' \
  "$test_dir/incomplete-switch-recovery.log"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "stable_session"
provider = config["model_providers"]["stable_session"]
assert provider["base_url"] == "https://gateway.test/v1"
assert provider["env_key"] == "TEST_PROVIDER_KEY"
PY

: > "$mock_log"
set +e
printf 'y\n' | env "${common_env[@]}" \
  MOCK_ACTIVE_UNIT="$third_party_name" \
  MOCK_ENABLED_UNIT="$third_party_name" \
  MOCK_FAIL_DISABLE_UNIT="$third_party_name" \
  bash "$repo_dir/use-official.sh" > "$test_dir/source-stop-failure.log" 2>&1
source_stop_failure_status=$?
set -e
[[ $source_stop_failure_status != 0 ]]
grep -Fq '切换失败；已恢复切换前配置和服务模式' "$test_dir/source-stop-failure.log"
grep -Fq "systemctl:start $third_party_name" "$mock_log"
if grep -Fq "systemctl:restart $official_name" "$mock_log"; then
  printf 'official service was started after the source service failed to stop\n' >&2
  exit 1
fi

printf 'y\n' | env "${common_env[@]}" \
  MOCK_ACTIVE_UNIT="$third_party_name" \
  MOCK_ENABLED_UNIT="$third_party_name" \
  bash "$repo_dir/use-official.sh" > "$test_dir/use-official-again.log"

: > "$mock_log"
set +e
env "${common_env[@]}" \
  MOCK_ACTIVE_UNIT="$official_name" \
  MOCK_ENABLED_UNIT="$official_name" \
  MOCK_FAIL_RESTART_UNIT="$third_party_name" \
  bash "$repo_dir/use-third-party.sh" > "$test_dir/third-party-start-failure.log" 2>&1
third_party_start_failure_status=$?
set -e
[[ $third_party_start_failure_status != 0 ]]
grep -Fq '切换失败；已恢复切换前配置和服务模式' "$test_dir/third-party-start-failure.log"
grep -Fq "systemctl:start $official_name" "$mock_log"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "stable_session"
provider = config["model_providers"]["stable_session"]
assert provider["base_url"] == "https://chatgpt.com/backend-api/codex"
assert provider["requires_openai_auth"] is True
assert "env_key" not in provider
PY

set +e
bash "$repo_dir/status.sh" --bad >/dev/null 2>&1
status_code=$?
set -e
[[ $status_code == 2 ]]

# Rollback must fail closed when an exact managed path has been replaced, and
# it must leave files outside the ownership manifest untouched.
# shellcheck disable=SC1090
source "$state_file"
saved_live_config="$test_dir/saved-live-config"
mv "$config_file" "$saved_live_config"
mkdir "$config_file"
set +e
printf 'ROLLBACK\n' | env "${common_env[@]}" \
  bash "$repo_dir/rollback.sh" > "$test_dir/rollback-config-directory.log" 2>&1
rollback_config_directory_status=$?
set -e
[[ $rollback_config_directory_status != 0 ]]
[[ -d "$config_file" ]]
[[ -z $(find "$config_file" -mindepth 1 -print -quit) ]]
[[ -f "$state_file" && -f "$secret_file" ]]
grep -Fq '用户配置路径存在且不是普通文件' \
  "$test_dir/rollback-config-directory.log"
rmdir "$config_file"
mv "$saved_live_config" "$config_file"

managed_profile="$codex_home/$PROVIDER_ID.config.toml"
saved_managed_profile="$test_dir/saved-managed-profile"
foreign_profile_target="$test_dir/foreign-profile-target"
printf 'foreign profile target\n' > "$foreign_profile_target"
mv "$managed_profile" "$saved_managed_profile"
ln -s "$foreign_profile_target" "$managed_profile"
set +e
printf 'ROLLBACK\n' | env "${common_env[@]}" \
  bash "$repo_dir/rollback.sh" > "$test_dir/rollback-symlink.log" 2>&1
rollback_symlink_status=$?
set -e
[[ $rollback_symlink_status != 0 ]]
[[ -L "$managed_profile" ]]
grep -Fxq 'foreign profile target' "$foreign_profile_target"
[[ -f "$state_file" ]]
grep -Fq '受管 Provider 文件缺失、被替换或内容不匹配' \
  "$test_dir/rollback-symlink.log"
rm "$managed_profile"
mv "$saved_managed_profile" "$managed_profile"

foreign_record="$PROVIDERS_DIR/foreign.env"
foreign_secret="$PROVIDER_SECRETS_DIR/foreign.env"
foreign_profile="$codex_home/foreign.config.toml"
printf 'foreign record\n' > "$foreign_record"
printf 'foreign secret\n' > "$foreign_secret"
printf 'foreign profile\n' > "$foreign_profile"

rollback_failure_snapshot="$test_dir/rollback-failure-snapshot"
mkdir -p "$rollback_failure_snapshot"
cp -p "$state_file" "$rollback_failure_snapshot/state"
cp -p "$config_file" "$rollback_failure_snapshot/config"
cp -p "$secret_file" "$rollback_failure_snapshot/active-secret"
cp -p "$third_party_unit" "$rollback_failure_snapshot/third-party-unit"
cp -p "$official_unit" "$rollback_failure_snapshot/official-unit"
cp -p "$command_file" "$rollback_failure_snapshot/command"
cp -p "$PROVIDERS_DIR/$PROVIDER_ID.env" "$rollback_failure_snapshot/record"
cp -p "$PROVIDER_SECRETS_DIR/$PROVIDER_ID.env" "$rollback_failure_snapshot/secret"
cp -p "$codex_home/$PROVIDER_ID.config.toml" "$rollback_failure_snapshot/profile"
rollback_daemon_count="$test_dir/rollback-daemon-count"
set +e
printf 'ROLLBACK\n' | env "${common_env[@]}" \
  MOCK_ACTIVE_UNIT="$official_name" \
  MOCK_ENABLED_UNIT="$official_name" \
  MOCK_FAIL_DAEMON_ONCE=yes \
  MOCK_DAEMON_COUNT_FILE="$rollback_daemon_count" \
  bash "$repo_dir/rollback.sh" > "$test_dir/rollback-transaction-failure.log" 2>&1
rollback_transaction_failure_status=$?
set -e
[[ $rollback_transaction_failure_status != 0 ]]
grep -Fq '回滚失败；已恢复回滚前的文件和服务模式' \
  "$test_dir/rollback-transaction-failure.log"
cmp -s "$state_file" "$rollback_failure_snapshot/state"
cmp -s "$config_file" "$rollback_failure_snapshot/config"
cmp -s "$secret_file" "$rollback_failure_snapshot/active-secret"
cmp -s "$third_party_unit" "$rollback_failure_snapshot/third-party-unit"
cmp -s "$official_unit" "$rollback_failure_snapshot/official-unit"
cmp -s "$command_file" "$rollback_failure_snapshot/command"
cmp -s "$PROVIDERS_DIR/$PROVIDER_ID.env" "$rollback_failure_snapshot/record"
cmp -s "$PROVIDER_SECRETS_DIR/$PROVIDER_ID.env" "$rollback_failure_snapshot/secret"
cmp -s "$codex_home/$PROVIDER_ID.config.toml" "$rollback_failure_snapshot/profile"
[[ $(< "$rollback_daemon_count") == 2 ]]

printf 'ROLLBACK\n' | env "${common_env[@]}" \
  bash "$repo_dir/rollback.sh" > "$test_dir/rollback.log"
cmp -s "$third_party_unit" "$backup_dir/codex-remote-provider.service"
cmp -s "$official_unit" "$backup_dir/codex-remote-official.service"
cmp -s "$command_file" "$backup_dir/codex-rp"
cmp -s "$config_file" "$backup_dir/config.toml"
[[ ! -e "$secret_file" ]]
[[ ! -e "$state_file" ]]
grep -Fxq 'foreign record' "$foreign_record"
grep -Fxq 'foreign secret' "$foreign_secret"
grep -Fxq 'foreign profile' "$foreign_profile"
find "$state_dir/audit" -maxdepth 1 -type f -name 'state-*.env' | grep -q .
grep -Fq '现在可以重新安装' "$test_dir/rollback.log"

legacy_rollback_dir="$test_dir/legacy-rollback"
legacy_rollback_home="$legacy_rollback_dir/codex-home"
legacy_rollback_backup="$legacy_rollback_dir/backup"
legacy_rollback_records="$legacy_rollback_dir/provider-records"
legacy_rollback_secrets="$legacy_rollback_dir/provider-secrets"
legacy_rollback_state="$legacy_rollback_dir/state.env"
legacy_rollback_secret="$legacy_rollback_dir/provider.env"
mkdir -p "$legacy_rollback_home" "$legacy_rollback_backup" \
  "$legacy_rollback_records" "$legacy_rollback_secrets"
chmod 700 "$legacy_rollback_backup"
printf 'model = "before-kit"\n' > "$legacy_rollback_backup/config.toml"
cat > "$legacy_rollback_home/config.toml" <<'EOF'
model_provider = "legacy_provider"
model = "legacy-model"
model_reasoning_effort = "high"
EOF
printf 'model_provider = "legacy_provider"\nmodel = "legacy-model"\nmodel_reasoning_effort = "high"\n' \
  > "$legacy_rollback_home/legacy_provider.config.toml"
printf 'LEGACY_KEY="legacy_value"\n' > "$legacy_rollback_secret"
chmod 600 "$legacy_rollback_secret"
printf 'foreign exact record\n' \
  > "$legacy_rollback_records/legacy_provider.env"
printf 'foreign exact secret\n' \
  > "$legacy_rollback_secrets/legacy_provider.env"
{
  printf 'PROVIDER_ID=%q\n' legacy_provider
  printf 'ENV_NAME=%q\n' LEGACY_KEY
  printf 'BASE_URL=%q\n' https://legacy.test/v1
  printf 'MODEL=%q\n' legacy-model
  printf 'REASONING=%q\n' high
  printf 'CODEX_HOME_DIR=%q\n' "$legacy_rollback_home"
  printf 'CODEX_BIN_PATH=%q\n' "$mock_codex"
  printf 'COMMAND_FILE=%q\n' "$legacy_rollback_dir/codex-rp"
  printf 'BACKUP_DIR=%q\n' "$legacy_rollback_backup"
  printf 'THIRD_PARTY_UNIT_FILE=%q\n' \
    "$legacy_rollback_dir/codex-remote-provider.service"
  printf 'OFFICIAL_UNIT_FILE=%q\n' \
    "$legacy_rollback_dir/codex-remote-official.service"
  printf 'LEGACY_ENABLED=%q\n' no
  printf 'LEGACY_ACTIVE=%q\n' no
} > "$legacy_rollback_state"
chmod 600 "$legacy_rollback_state"
printf 'ROLLBACK\n' | env \
  PATH="$mock_bin:$PATH" \
  MOCK_LOG="$mock_log" \
  CODEX_RP_STATE_FILE="$legacy_rollback_state" \
  CODEX_RP_SECRET_FILE="$legacy_rollback_secret" \
  CODEX_RP_PROVIDERS_DIR="$legacy_rollback_records" \
  CODEX_RP_PROVIDER_SECRETS_DIR="$legacy_rollback_secrets" \
  bash "$repo_dir/rollback.sh" > "$test_dir/legacy-rollback.log"
grep -Fxq 'foreign exact record' \
  "$legacy_rollback_records/legacy_provider.env"
grep -Fxq 'foreign exact secret' \
  "$legacy_rollback_secrets/legacy_provider.env"
[[ ! -e "$legacy_rollback_secret" ]]
[[ ! -e "$legacy_rollback_state" ]]

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
  printf 'SESSION_PROVIDER_ID=%q\n' stable_session
  printf 'MODEL=%q\n' gpt-5.6-sol
  printf 'REASONING=%q\n' high
  printf 'CODEX_BIN_PATH=%q\n' "$mock_codex"
  printf 'COMMAND_FILE=%q\n' "$collision_command"
  printf 'BACKUP_DIR=%q\n' "$collision_dir/backup"
  printf 'THIRD_PARTY_UNIT_FILE=%q\n' "$collision_third_party_unit"
  printf 'OFFICIAL_UNIT_FILE=%q\n' "$collision_official_unit"
} > "$collision_state"
chmod 600 "$collision_state"
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

failed_refresh_dir="$test_dir/failed-refresh"
failed_refresh_home="$failed_refresh_dir/codex-home"
failed_refresh_backup="$failed_refresh_dir/backup"
failed_refresh_state="$failed_refresh_dir/state.env"
failed_refresh_config="$failed_refresh_home/config.toml"
failed_refresh_third_party="$failed_refresh_dir/codex-remote-provider.service"
failed_refresh_official="$failed_refresh_dir/codex-remote-official.service"
failed_refresh_command="$failed_refresh_dir/codex-rp"
mkdir -p "$failed_refresh_home"
cat > "$failed_refresh_config" <<'EOF'
model_provider = "stable_session"
model = "third-model"
model_reasoning_effort = "high"

# BEGIN codex-remote-provider-kit:stable_session
[model_providers.stable_session]
name = "stable_session"
base_url = "https://gateway.test/v1"
env_key = "TEST_PROVIDER_KEY"
wire_api = "responses"
# END codex-remote-provider-kit:stable_session
EOF
printf '# Managed by codex-remote-provider-kit\n' > "$failed_refresh_third_party"
printf '# external official unit\n' > "$failed_refresh_official"
printf '# Managed by codex-remote-provider-kit\n' > "$failed_refresh_command"
printf 'TEST_PROVIDER_KEY="valid"\n' > "$failed_refresh_dir/provider.env"
{
  printf 'PROVIDER_ID=%q\n' third_party
  printf 'SESSION_PROVIDER_ID=%q\n' stable_session
  printf 'ENV_NAME=%q\n' TEST_PROVIDER_KEY
  printf 'BASE_URL=%q\n' https://gateway.test/v1
  printf 'MODEL=%q\n' third-model
  printf 'REASONING=%q\n' high
  printf 'CODEX_HOME_DIR=%q\n' "$failed_refresh_home"
  printf 'CODEX_BIN_PATH=%q\n' "$mock_codex"
  printf 'COMMAND_FILE=%q\n' "$failed_refresh_command"
  printf 'BACKUP_DIR=%q\n' "$failed_refresh_backup"
  printf 'THIRD_PARTY_UNIT_FILE=%q\n' "$failed_refresh_third_party"
  printf 'OFFICIAL_UNIT_FILE=%q\n' "$failed_refresh_official"
} > "$failed_refresh_state"
chmod 600 "$failed_refresh_state"
cp -p "$failed_refresh_state" "$failed_refresh_dir/original-state"
cp -p "$failed_refresh_config" "$failed_refresh_dir/original-config"
cp -p "$failed_refresh_official" "$failed_refresh_dir/original-official"
set +e
printf 'y\n' | env \
  PATH="$mock_bin:$PATH" \
  MOCK_LOG="$mock_log" \
  MOCK_ACTIVE_UNIT=${failed_refresh_third_party##*/} \
  MOCK_ENABLED_UNIT=${failed_refresh_third_party##*/} \
  MOCK_FAIL_RESTART_UNIT=${failed_refresh_official##*/} \
  CODEX_RP_STATE_FILE="$failed_refresh_state" \
  CODEX_RP_SECRET_FILE="$failed_refresh_dir/provider.env" \
  bash "$repo_dir/use-official.sh" > "$failed_refresh_dir/failure.log" 2>&1
failed_refresh_status=$?
set -e
[[ $failed_refresh_status != 0 ]]
cmp -s "$failed_refresh_state" "$failed_refresh_dir/original-state"
cmp -s "$failed_refresh_config" "$failed_refresh_dir/original-config"
cmp -s "$failed_refresh_official" "$failed_refresh_dir/original-official"
[[ ! -e "$failed_refresh_backup/codex-remote-official.service" ]]

printf 'mode switching and rollback lifecycle: ok\n'
