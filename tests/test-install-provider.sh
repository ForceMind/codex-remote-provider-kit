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
if [[ ${MOCK_FAIL_CODEX_STOP:-no} == yes \
    && ${1-} == remote-control && ${2-} == stop ]]; then
  exit 1
fi
EOF
cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl:%s\n' "$*" >> "$MOCK_LOG"
case ${1-} in
  is-enabled) [[ ${2-} == "${MOCK_ENABLED_UNIT:-}" ]]; exit ;;
  is-active) [[ ${2-} == "${MOCK_ACTIVE_UNIT:-}" ]]; exit ;;
esac
if [[ -n ${MOCK_FAIL_UNIT:-} && "$*" == "--quiet enable --now $MOCK_FAIL_UNIT" ]]; then
  exit 1
fi
if [[ -n ${MOCK_FAIL_START_UNIT:-} && "$*" == "start $MOCK_FAIL_START_UNIT" ]]; then
  exit 1
fi
EOF
chmod 755 "$mock_bin/codex" "$mock_bin/systemctl"

run_installer() {
  local fixture=${1:?fixture directory required}
  local installer_codex_home=${RUN_INSTALL_CODEX_HOME:-$fixture/codex-home}
  shift
  env \
    PATH="$mock_bin:$PATH" \
    MOCK_LOG="$mock_log" \
    THIRD_PARTY_API_KEY='test_token' \
    CODEX_RP_SECRET_FILE="$fixture/provider.env" \
    CODEX_RP_STATE_FILE="$fixture/state.env" \
    CODEX_RP_PROVIDERS_DIR="$fixture/provider-records" \
    CODEX_RP_PROVIDER_SECRETS_DIR="$fixture/provider-secrets" \
    CODEX_RP_THIRD_PARTY_UNIT_FILE="$fixture/codex-remote-provider.service" \
    CODEX_RP_OFFICIAL_UNIT_FILE="$fixture/codex-remote-official.service" \
    CODEX_RP_COMMAND_FILE="$fixture/codex-rp" \
    "$@" \
    bash "$repo_dir/install-provider.sh" \
      --base-url https://gateway.test/v1 \
      --model gpt-5.6-sol \
      --provider-id third_party \
      --codex-home "$installer_codex_home" \
      --codex-bin "$mock_bin/codex"
}

success_dir="$test_dir/success"
mkdir -p "$success_dir/codex-home"
success_dir_metadata=$(stat -c '%u:%g:%a' "$success_dir")
success_home_metadata=$(stat -c '%u:%g:%a' "$success_dir/codex-home")
run_installer "$success_dir" > "$test_dir/success.log"
[[ $(stat -c '%u:%g:%a' "$success_dir") == "$success_dir_metadata" ]]
[[ $(stat -c '%u:%g:%a' "$success_dir/codex-home") == "$success_home_metadata" ]]
[[ -s "$success_dir/state.env" ]]
grep -Fxq 'SESSION_PROVIDER_ID=third_party' "$success_dir/state.env"
grep -Fxq 'OWNERSHIP_SCHEMA=1' "$success_dir/state.env"
grep -Fxq 'MANAGED_PROVIDER_IDS=third_party' "$success_dir/state.env"
grep -Fxq 'PROFILE_MARKERS_REQUIRED=yes' "$success_dir/state.env"
grep -Fxq 'PROVIDERS_DIR_CREATED_BY_KIT=yes' "$success_dir/state.env"
grep -Fxq 'PROVIDER_SECRETS_DIR_CREATED_BY_KIT=yes' "$success_dir/state.env"
grep -Fxq 'INSTALLED_PROFILE_PREEXISTED=no' "$success_dir/state.env"
[[ $(stat -c '%a' "$success_dir/state.env") == 600 ]]
[[ $(stat -c '%a' "$success_dir/provider.env") == 600 ]]
grep -Fxq 'THIRD_PARTY_API_KEY="test_token"' "$success_dir/provider.env"
grep -Fxq 'THIRD_PARTY_API_KEY="test_token"' \
  "$success_dir/provider-secrets/third_party.env"
grep -Fxq 'BASE_URL=https://gateway.test/v1' \
  "$success_dir/provider-records/third_party.env"
[[ $(stat -c '%a' "$success_dir/provider-records/third_party.env") == 600 ]]
[[ $(stat -c '%a' "$success_dir/provider-secrets/third_party.env") == 600 ]]
grep -Fxq '# Managed by codex-remote-provider-kit' \
  "$success_dir/codex-remote-provider.service"
grep -Fxq '# Managed by codex-remote-provider-kit' \
  "$success_dir/codex-remote-official.service"
grep -Fq -- '-c model_provider=third_party' \
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

derived_dir="$test_dir/derived"
mkdir -p "$derived_dir/codex-home"
derived_id=$(bash -c 'source "$1/lib.sh"; provider_id_from_base_url "$2"' \
  _ "$repo_dir" https://derived-gateway.test/v1)
env \
  PATH="$mock_bin:$PATH" \
  MOCK_LOG="$mock_log" \
  THIRD_PARTY_API_KEY='derived_token' \
  CODEX_RP_SECRET_FILE="$derived_dir/provider.env" \
  CODEX_RP_STATE_FILE="$derived_dir/state.env" \
  CODEX_RP_PROVIDERS_DIR="$derived_dir/provider-records" \
  CODEX_RP_PROVIDER_SECRETS_DIR="$derived_dir/provider-secrets" \
  CODEX_RP_THIRD_PARTY_UNIT_FILE="$derived_dir/codex-remote-provider.service" \
  CODEX_RP_OFFICIAL_UNIT_FILE="$derived_dir/codex-remote-official.service" \
  CODEX_RP_COMMAND_FILE="$derived_dir/codex-rp" \
  bash "$repo_dir/install-provider.sh" \
    --base-url https://derived-gateway.test/v1 \
    --model gpt-5.6-sol \
    --codex-home "$derived_dir/codex-home" \
    --codex-bin "$mock_bin/codex" > "$test_dir/derived.log"
grep -Fxq "PROVIDER_ID=$derived_id" "$derived_dir/state.env"
grep -Fxq "SESSION_PROVIDER_ID=$derived_id" "$derived_dir/state.env"
[[ -f "$derived_dir/provider-records/$derived_id.env" ]]
[[ -f "$derived_dir/provider-secrets/$derived_id.env" ]]

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
grep -Fq '已恢复安装前配置和服务' "$test_dir/failure.log"

recovery_failure_dir="$test_dir/recovery-failure"
mkdir -p "$recovery_failure_dir/codex-home"
printf 'model = "original-model"\n' > "$recovery_failure_dir/codex-home/config.toml"
printf '# original third-party unit\n' \
  > "$recovery_failure_dir/codex-remote-provider.service"
printf '# original official unit\n' \
  > "$recovery_failure_dir/codex-remote-official.service"
set +e
run_installer "$recovery_failure_dir" \
  MOCK_ACTIVE_UNIT=codex-remote-provider.service \
  MOCK_ENABLED_UNIT=codex-remote-provider.service \
  MOCK_FAIL_UNIT=codex-remote-provider.service \
  MOCK_FAIL_START_UNIT=codex-remote-provider.service \
  MOCK_FAIL_CODEX_STOP=yes \
  > "$test_dir/recovery-failure.log" 2>&1
recovery_failure_status=$?
set -e
[[ $recovery_failure_status != 0 ]]
grep -Fq '自动恢复失败：无法重新启动 codex-remote-provider.service' \
  "$test_dir/recovery-failure.log"
grep -Fq '自动恢复失败：无法停止当前 Codex Remote daemon' \
  "$test_dir/recovery-failure.log"
grep -Fq '安装失败，且自动恢复不完整' "$test_dir/recovery-failure.log"
[[ ! -e "$recovery_failure_dir/provider.env" ]]
[[ ! -e "$recovery_failure_dir/state.env" ]]

symlink_dir="$test_dir/symlink-directory"
mkdir -p "$symlink_dir/codex-home" "$symlink_dir/foreign-records"
ln -s "$symlink_dir/foreign-records" "$symlink_dir/provider-records"
set +e
run_installer "$symlink_dir" > "$test_dir/symlink-directory.log" 2>&1
symlink_directory_status=$?
set -e
[[ $symlink_directory_status != 0 ]]
grep -Fq '供应商记录目录必须由 root 拥有' "$test_dir/symlink-directory.log"
[[ -z $(find "$symlink_dir/foreign-records" -mindepth 1 -print -quit) ]]

symlink_profile_dir="$test_dir/symlink-profile"
mkdir -p "$symlink_profile_dir/codex-home"
printf 'foreign profile target\n' > "$symlink_profile_dir/foreign-profile"
ln -s "$symlink_profile_dir/foreign-profile" \
  "$symlink_profile_dir/codex-home/third_party.config.toml"
set +e
run_installer "$symlink_profile_dir" > "$test_dir/symlink-profile.log" 2>&1
symlink_profile_status=$?
set -e
[[ $symlink_profile_status != 0 ]]
grep -Fq '受管目标路径是符号链接' "$test_dir/symlink-profile.log"
grep -Fxq 'foreign profile target' "$symlink_profile_dir/foreign-profile"
[[ -L "$symlink_profile_dir/codex-home/third_party.config.toml" ]]

directory_target_dir="$test_dir/directory-target"
mkdir -p "$directory_target_dir/codex-home/config.toml"
set +e
run_installer "$directory_target_dir" > "$test_dir/directory-target.log" 2>&1
directory_target_status=$?
set -e
[[ $directory_target_status != 0 ]]
grep -Fq '受管目标已存在但不是普通文件' "$test_dir/directory-target.log"
[[ -d "$directory_target_dir/codex-home/config.toml" ]]

untrusted_writable_parent="$test_dir/untrusted-writable-parent"
trusted_codex_fixture="$test_dir/trusted-codex-fixture"
mkdir -p "$untrusted_writable_parent" "$trusted_codex_fixture"
chmod 0777 "$untrusted_writable_parent"
set +e
RUN_INSTALL_CODEX_HOME="$untrusted_writable_parent/codex-home" \
  run_installer "$trusted_codex_fixture" \
  > "$test_dir/untrusted-codex-home.log" 2>&1
untrusted_codex_home_status=$?
set -e
[[ $untrusted_codex_home_status != 0 ]]
grep -Fq '受管路径的最近已有目录必须由 root 拥有' \
  "$test_dir/untrusted-codex-home.log"
[[ ! -e "$untrusted_writable_parent/codex-home" ]]
[[ -z $(find "$untrusted_writable_parent" -mindepth 1 -print -quit) ]]
chmod 0700 "$untrusted_writable_parent"

untrusted_owned_parent="$test_dir/untrusted-owned-parent"
trusted_override_fixture="$test_dir/trusted-override-fixture"
mkdir -p "$untrusted_owned_parent" "$trusted_override_fixture/codex-home"
chmod 0700 "$untrusted_owned_parent"
chown 65534:65534 "$untrusted_owned_parent"
untrusted_overrides=(
  "CODEX_RP_SECRET_FILE=$untrusted_owned_parent/provider.env"
  "CODEX_RP_STATE_FILE=$untrusted_owned_parent/state.env"
  "CODEX_RP_PROVIDERS_DIR=$untrusted_owned_parent/provider-records"
  "CODEX_RP_PROVIDER_SECRETS_DIR=$untrusted_owned_parent/provider-secrets"
  "CODEX_RP_THIRD_PARTY_UNIT_FILE=$untrusted_owned_parent/provider.service"
  "CODEX_RP_OFFICIAL_UNIT_FILE=$untrusted_owned_parent/official.service"
  "CODEX_RP_COMMAND_FILE=$untrusted_owned_parent/codex-rp"
)
for override_index in "${!untrusted_overrides[@]}"; do
  set +e
  run_installer "$trusted_override_fixture" \
    "${untrusted_overrides[override_index]}" \
    > "$test_dir/untrusted-override-$override_index.log" 2>&1
  untrusted_override_status=$?
  set -e
  [[ $untrusted_override_status != 0 ]]
  grep -Fq '受管路径的最近已有目录必须由 root 拥有' \
    "$test_dir/untrusted-override-$override_index.log"
  [[ -z $(find "$untrusted_owned_parent" -mindepth 1 -print -quit) ]]
done
chown 0:0 "$untrusted_owned_parent"

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
