#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d)
cleanup() { rm -rf -- "$test_dir"; }
trap cleanup EXIT

real_install=$(command -v install)
real_cp=$(command -v cp)
mock_bin="$test_dir/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target=${!#}
printf 'install:%s\n' "$*" >> "$MOCK_LOG"
if [[ -n ${MOCK_FAIL_INSTALL_TARGET:-} \
    && "$target" == "$MOCK_FAIL_INSTALL_TARGET" \
    && ! -e "$MOCK_FAIL_SENTINEL" ]]; then
  "$REAL_INSTALL" "$@"
  : > "$MOCK_FAIL_SENTINEL"
  exit 91
fi
exec "$REAL_INSTALL" "$@"
EOF

cat > "$mock_bin/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source_path=${@: -2:1}
target_path=${@: -1}
printf 'cp:%s\n' "$*" >> "$MOCK_LOG"
if [[ ! -e "$MOCK_FAIL_SENTINEL" ]] \
    && { [[ -n ${MOCK_FAIL_CP_TARGET:-} \
          && "$target_path" == "$MOCK_FAIL_CP_TARGET" ]] \
      || [[ -n ${MOCK_FAIL_CP_SOURCE:-} \
          && "$source_path" == "$MOCK_FAIL_CP_SOURCE" ]]; }; then
  "$REAL_CP" "$@"
  : > "$MOCK_FAIL_SENTINEL"
  exit 92
fi
exec "$REAL_CP" "$@"
EOF

cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'systemctl:%s\n' "$*" >> "$MOCK_LOG"
if [[ ${1-} == is-active \
    && -n ${MOCK_REPLACE_COMMAND_ON_QUERY:-} \
    && ! -e "$MOCK_FAIL_SENTINEL" ]]; then
  printf '# concurrently created external launcher\n' \
    > "$MOCK_REPLACE_COMMAND_ON_QUERY"
  chmod 755 "$MOCK_REPLACE_COMMAND_ON_QUERY"
  : > "$MOCK_FAIL_SENTINEL"
fi
case ${1-} in
  is-active)
    [[ ${2-} == "$MOCK_ACTIVE_UNIT" ]]
    ;;
  is-enabled)
    [[ ${2-} == "$MOCK_ENABLED_UNIT" ]]
    ;;
  daemon-reload)
    count=0
    if [[ -r "$MOCK_DAEMON_COUNT_FILE" ]]; then
      read -r count < "$MOCK_DAEMON_COUNT_FILE"
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$MOCK_DAEMON_COUNT_FILE"
    if [[ ${MOCK_FAIL_DAEMON_ALWAYS:-no} == yes \
        || ( ${MOCK_FAIL_DAEMON_ONCE:-no} == yes && $count == 1 ) ]]; then
      exit 93
    fi
    ;;
esac
EOF

cat > "$mock_bin/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$mock_bin/install" "$mock_bin/cp" "$mock_bin/systemctl" \
  "$mock_bin/codex"

setup_fixture() {
  local fixture_name=${1:?fixture name required}

  case_dir="$test_dir/$fixture_name"
  codex_home="$case_dir/codex-home"
  backup_dir="$case_dir/backup"
  temp_dir="$case_dir/tmp"
  original_dir="$case_dir/original"
  state_file="$case_dir/state.env"
  config_file="$codex_home/config.toml"
  secret_file="$case_dir/provider.env"
  third_party_unit="$case_dir/codex-remote-provider.service"
  official_unit="$case_dir/codex-remote-official.service"
  command_file="$case_dir/codex-rp"
  mock_log="$case_dir/mock.log"
  daemon_count_file="$case_dir/daemon-count"
  failure_sentinel="$case_dir/failure-fired"
  output_file="$case_dir/output.log"

  mkdir -p "$codex_home" "$temp_dir" "$original_dir"
  cat > "$config_file" <<'EOF'
model_provider = "third_party"
model = "old-model"
model_reasoning_effort = "low"

# BEGIN codex-remote-provider-kit:third_party
[model_providers.third_party]
name = "third_party"
base_url = "https://old.test/v1"
env_key = "OLD_PROVIDER_KEY"
wire_api = "responses"
# END codex-remote-provider-kit:third_party
EOF
  cat > "$third_party_unit" <<'EOF'
# Managed by codex-remote-provider-kit
# original third-party unit
EOF
  cat > "$official_unit" <<'EOF'
# external official unit
EOF
  cat > "$command_file" <<'EOF'
#!/usr/bin/env bash
# Managed by codex-remote-provider-kit
printf 'original launcher\n'
EOF
  printf 'TEST_PROVIDER_KEY="fixture-key"\n' > "$secret_file"
  {
    printf 'PROVIDER_ID=%q\n' third_party
    printf 'ENV_NAME=%q\n' TEST_PROVIDER_KEY
    printf 'BASE_URL=%q\n' https://gateway.test/v1
    printf 'MODEL=%q\n' new-model
    printf 'REASONING=%q\n' high
    printf 'CODEX_HOME_DIR=%q\n' "$codex_home"
    printf 'CODEX_BIN_PATH=%q\n' "$mock_bin/codex"
    printf 'COMMAND_FILE=%q\n' "$command_file"
    printf 'BACKUP_DIR=%q\n' "$backup_dir"
    printf 'THIRD_PARTY_UNIT_FILE=%q\n' "$third_party_unit"
    printf 'OFFICIAL_UNIT_FILE=%q\n' "$official_unit"
  } > "$state_file"

  chmod 600 "$state_file" "$third_party_unit" "$secret_file"
  chmod 640 "$config_file" "$official_unit"
  chmod 750 "$command_file"
  "$real_cp" -p "$state_file" "$original_dir/state"
  "$real_cp" -p "$config_file" "$original_dir/config"
  "$real_cp" -p "$third_party_unit" "$original_dir/third-party-unit"
  "$real_cp" -p "$official_unit" "$original_dir/official-unit"
  "$real_cp" -p "$command_file" "$original_dir/command"

  common_env=(
    PATH="$mock_bin:$PATH"
    TMPDIR="$temp_dir"
    REAL_INSTALL="$real_install"
    REAL_CP="$real_cp"
    MOCK_LOG="$mock_log"
    MOCK_FAIL_SENTINEL="$failure_sentinel"
    MOCK_DAEMON_COUNT_FILE="$daemon_count_file"
    MOCK_ACTIVE_UNIT="${third_party_unit##*/}"
    MOCK_ENABLED_UNIT="${third_party_unit##*/}"
    CODEX_RP_STATE_FILE="$state_file"
    CODEX_RP_SECRET_FILE="$secret_file"
  )
}

run_refresh() {
  set +e
  env "${common_env[@]}" "$@" \
    bash "$repo_dir/refresh-units.sh" > "$output_file" 2>&1
  refresh_status=$?
  set -e
}

assert_file_matches_original() {
  local current_file=${1:?current file required}
  local original_file=${2:?original file required}

  cmp -s "$current_file" "$original_file"
  [[ $(stat -c '%a' -- "$current_file") \
      == "$(stat -c '%a' -- "$original_file")" ]]
}

assert_live_files_restored() {
  assert_file_matches_original "$state_file" "$original_dir/state"
  assert_file_matches_original "$config_file" "$original_dir/config"
  assert_file_matches_original "$third_party_unit" "$original_dir/third-party-unit"
  assert_file_matches_original "$official_unit" "$original_dir/official-unit"
  assert_file_matches_original "$command_file" "$original_dir/command"
}

assert_empty_temp_dir() {
  if find "$temp_dir" -mindepth 1 -print -quit | grep -q .; then
    printf 'transaction work directory leaked under %s\n' "$temp_dir" >&2
    exit 1
  fi
}

assert_successful_rollback() {
  [[ $refresh_status != 0 ]]
  assert_live_files_restored
  [[ ! -e "$backup_dir" ]]
  grep -Fq '已恢复修改前的配置、状态、备份和启动文件' "$output_file"
  [[ $(< "$daemon_count_file") == 1 ]]
  assert_empty_temp_dir
}

run_install_failure() {
  local fixture_name=${1:?fixture name required}
  local target_kind=${2:?target kind required}
  local failure_target

  setup_fixture "$fixture_name"
  case "$target_kind" in
    backup-dir) failure_target=$backup_dir ;;
    config) failure_target=$config_file ;;
    state) failure_target=$state_file ;;
    third-party-unit) failure_target=$third_party_unit ;;
    official-unit) failure_target=$official_unit ;;
    launcher) failure_target=$command_file ;;
    *) printf 'unknown failure target: %s\n' "$target_kind" >&2; exit 1 ;;
  esac
  run_refresh MOCK_FAIL_INSTALL_TARGET="$failure_target"
  assert_successful_rollback
}

run_install_failure install-backup-dir backup-dir
run_install_failure install-config config
run_install_failure install-state state

setup_fixture concurrent-launcher
run_refresh MOCK_REPLACE_COMMAND_ON_QUERY="$command_file"
[[ $refresh_status != 0 ]]
assert_file_matches_original "$state_file" "$original_dir/state"
assert_file_matches_original "$config_file" "$original_dir/config"
assert_file_matches_original "$third_party_unit" "$original_dir/third-party-unit"
assert_file_matches_original "$official_unit" "$original_dir/official-unit"
grep -Fxq '# concurrently created external launcher' "$command_file"
[[ ! -e "$backup_dir" ]]
[[ ! -e "$daemon_count_file" ]]
assert_empty_temp_dir

setup_fixture symlink-launcher
mv "$command_file" "$case_dir/launcher-target"
ln -s "$case_dir/launcher-target" "$command_file"
run_refresh
[[ $refresh_status != 0 ]]
[[ -L "$command_file" ]]
grep -Fq '是符号链接，不能作为受管全局命令' "$output_file"
grep -Fq 'original launcher' "$case_dir/launcher-target"
[[ ! -e "$backup_dir" && ! -e "$daemon_count_file" ]]
assert_empty_temp_dir

setup_fixture foreign-third-party-unit
printf '# foreign third-party unit\n' > "$third_party_unit"
run_refresh
[[ $refresh_status != 0 ]]
grep -Fxq '# foreign third-party unit' "$third_party_unit"
grep -Fq '第三方 unit 已被非受管文件替换' "$output_file"
[[ ! -e "$backup_dir" && ! -e "$daemon_count_file" ]]
assert_empty_temp_dir

setup_fixture non-regular-official-unit
rm -f "$official_unit"
mkdir "$official_unit"
run_refresh
[[ $refresh_status != 0 ]]
[[ -d "$official_unit" ]]
[[ -z $(find "$official_unit" -mindepth 1 -print -quit) ]]
grep -Fq '官方 unit 目标已存在且不是普通文件' "$output_file"
[[ ! -e "$backup_dir" && ! -e "$daemon_count_file" ]]
assert_empty_temp_dir

setup_fixture official-unit-directory
rm -f "$official_unit"
mkdir "$official_unit"
run_refresh
[[ $refresh_status != 0 ]]
[[ -d "$official_unit" ]]
grep -Fq '官方 unit 目标已存在且不是普通文件' "$output_file"
[[ ! -e "$backup_dir" && ! -e "$daemon_count_file" ]]
assert_empty_temp_dir

setup_fixture official-unit-backup-directory
mkdir -p "$backup_dir/codex-remote-official.service"
run_refresh
[[ $refresh_status != 0 ]]
[[ -d "$backup_dir/codex-remote-official.service" ]]
grep -Fq '官方 unit 备份目标已存在且不是普通文件' "$output_file"
[[ ! -e "$daemon_count_file" ]]
assert_empty_temp_dir

setup_fixture copy-backup
run_refresh MOCK_FAIL_CP_TARGET="$backup_dir/codex-remote-official.service"
assert_successful_rollback

run_install_failure install-third-party-unit third-party-unit
run_install_failure install-official-unit official-unit
run_install_failure install-launcher launcher

setup_fixture daemon-reload
run_refresh MOCK_FAIL_DAEMON_ONCE=yes
[[ $refresh_status != 0 ]]
assert_live_files_restored
[[ ! -e "$backup_dir" ]]
grep -Fq '已恢复修改前的配置、状态、备份和启动文件' "$output_file"
[[ $(< "$daemon_count_file") == 2 ]]
assert_empty_temp_dir

setup_fixture absent-managed-targets
rm -f "$third_party_unit" "$official_unit" "$command_file"
run_refresh MOCK_FAIL_DAEMON_ONCE=yes
[[ $refresh_status != 0 ]]
assert_file_matches_original "$state_file" "$original_dir/state"
assert_file_matches_original "$config_file" "$original_dir/config"
[[ ! -e "$third_party_unit" && ! -e "$official_unit" && ! -e "$command_file" ]]
[[ ! -e "$backup_dir" ]]
[[ $(< "$daemon_count_file") == 2 ]]
assert_empty_temp_dir

setup_fixture official-mode
run_refresh \
  MOCK_ACTIVE_UNIT="${official_unit##*/}" \
  MOCK_ENABLED_UNIT="${official_unit##*/}" \
  MOCK_FAIL_DAEMON_ONCE=yes
[[ $refresh_status != 0 ]]
assert_live_files_restored
[[ ! -e "$backup_dir" ]]
[[ $(< "$daemon_count_file") == 2 ]]
assert_empty_temp_dir

setup_fixture persistent-daemon-reload
run_refresh MOCK_FAIL_DAEMON_ALWAYS=yes
[[ $refresh_status != 0 ]]
assert_live_files_restored
[[ ! -e "$backup_dir" ]]
grep -Fq '至少一项回滚操作失败' "$output_file"
if grep -Fq '已恢复修改前' "$output_file"; then
  printf 'persistent daemon-reload failure was incorrectly reported as restored\n' >&2
  exit 1
fi
[[ $(< "$daemon_count_file") == 2 ]]
preserved_work_dir=$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n "$preserved_work_dir" && -f "$preserved_work_dir/state" ]]
[[ $(stat -c '%a' -- "$preserved_work_dir") == 700 ]]
grep -Fq "事务快照已保留在 root-only 临时目录：$preserved_work_dir" "$output_file"

setup_fixture preexisting-backup
mkdir -m 751 "$backup_dir"
cp -p "$official_unit" "$backup_dir/codex-remote-official.service"
chmod 600 "$backup_dir/codex-remote-official.service"
"$real_cp" -p "$backup_dir/codex-remote-official.service" \
  "$original_dir/official-unit-backup"
run_refresh MOCK_FAIL_DAEMON_ONCE=yes
[[ $refresh_status != 0 ]]
assert_live_files_restored
assert_file_matches_original "$backup_dir/codex-remote-official.service" \
  "$original_dir/official-unit-backup"
[[ $(stat -c '%a' -- "$backup_dir") == 751 ]]
[[ $(< "$daemon_count_file") == 2 ]]
assert_empty_temp_dir

setup_fixture snapshot-copy
run_refresh MOCK_FAIL_CP_SOURCE="$state_file"
[[ $refresh_status != 0 ]]
assert_live_files_restored
[[ ! -e "$backup_dir" ]]
[[ ! -e "$daemon_count_file" ]]
assert_empty_temp_dir

setup_fixture staging-config
printf 'this is not valid TOML =\n' > "$config_file"
chmod 640 "$config_file"
"$real_cp" -p "$config_file" "$original_dir/config"
run_refresh
[[ $refresh_status != 0 ]]
assert_live_files_restored
[[ ! -e "$backup_dir" ]]
[[ ! -e "$daemon_count_file" ]]
assert_empty_temp_dir

setup_fixture success
run_refresh
[[ $refresh_status == 0 ]]
cmp -s "$backup_dir/codex-remote-official.service" "$original_dir/official-unit"
[[ $(stat -c '%a' -- "$backup_dir") == 700 ]]
grep -Fxq 'SESSION_PROVIDER_ID=third_party' "$state_file"
grep -Fxq 'OFFICIAL_UNIT_EXISTED=yes' "$state_file"
grep -Fxq 'OFFICIAL_UNIT_ENABLED=no' "$state_file"
grep -Fxq 'OFFICIAL_UNIT_ACTIVE=no' "$state_file"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "third_party"
assert config["model"] == "new-model"
assert config["model_reasoning_effort"] == "high"
provider = config["model_providers"]["third_party"]
assert provider["base_url"] == "https://gateway.test/v1"
assert provider["env_key"] == "TEST_PROVIDER_KEY"
PY
grep -Fxq '# Managed by codex-remote-provider-kit' "$third_party_unit"
grep -Fxq '# Managed by codex-remote-provider-kit' "$official_unit"
grep -Fxq '# Managed by codex-remote-provider-kit' "$command_file"
grep -Fq 'model_provider=third_party' "$third_party_unit"
grep -Fq 'model_provider=third_party' "$official_unit"
[[ -x "$command_file" ]]
[[ $(< "$daemon_count_file") == 1 ]]
assert_empty_temp_dir

printf 'refresh-units independent transaction rollback: ok\n'
