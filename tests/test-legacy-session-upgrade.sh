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
providers_dir="$test_dir/provider-records"
provider_secrets_dir="$test_dir/provider-secrets"
backup_dir="$test_dir/backup"
mkdir -p "$mock_bin" "$codex_home" "$providers_dir" "$provider_secrets_dir" "$backup_dir"
chmod 700 "$providers_dir" "$provider_secrets_dir"

mock_log="$test_dir/mock.log"
cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl:%s\n' "$*" >> "$MOCK_LOG"
case ${1-} in
  is-active) [[ ${2-} == "${MOCK_ACTIVE_UNIT:-}" ]] ;;
  is-enabled)
    [[ ${2-} == "${MOCK_ENABLED_UNIT:-}" ]]
    printf 'enabled\n'
    ;;
  show) printf 'ActiveState=active\nSubState=exited\nResult=success\nUnitFileState=enabled\n' ;;
esac
EOF
cat > "$mock_bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codex:%s\n' "$*" >> "$MOCK_LOG"
[[ ${1-} == remote-control && ${2-} == stop ]]
EOF
chmod 755 "$mock_bin/systemctl" "$mock_bin/codex"

state_file="$test_dir/state.env"
active_secret_file="$test_dir/provider.env"
config_file="$codex_home/config.toml"
third_party_unit="$test_dir/codex-remote-provider.service"
official_unit="$test_dir/codex-remote-official.service"
command_file="$test_dir/codex-rp"
third_party_name=${third_party_unit##*/}

write_legacy_state() {
  {
    printf 'PROVIDER_ID=%q\n' provider_a
    printf 'INSTALLED_PROVIDER_ID=%q\n' provider_a
    printf 'OWNERSHIP_SCHEMA=%q\n' 1
    printf 'MANAGED_PROVIDER_IDS=%q\n' 'provider_a provider_b'
    printf 'PROFILE_MARKERS_REQUIRED=%q\n' no
    printf 'PROVIDERS_DIR_CREATED_BY_KIT=%q\n' no
    printf 'PROVIDER_SECRETS_DIR_CREATED_BY_KIT=%q\n' no
    printf 'INSTALLED_PROFILE_PREEXISTED=%q\n' no
    printf 'ENV_NAME=%q\n' PROVIDER_A_KEY
    printf 'BASE_URL=%q\n' https://a.test/v1
    printf 'MODEL=%q\n' model-a
    printf 'REASONING=%q\n' high
    printf 'CODEX_HOME_DIR=%q\n' "$codex_home"
    printf 'CODEX_BIN_PATH=%q\n' "$mock_bin/codex"
    printf 'COMMAND_FILE=%q\n' "$command_file"
    printf 'BACKUP_DIR=%q\n' "$backup_dir"
    printf 'PROVIDERS_DIR=%q\n' "$providers_dir"
    printf 'PROVIDER_SECRETS_DIR=%q\n' "$provider_secrets_dir"
    printf 'THIRD_PARTY_UNIT_FILE=%q\n' "$third_party_unit"
    printf 'OFFICIAL_UNIT_FILE=%q\n' "$official_unit"
  } > "$state_file"
  chmod 600 "$state_file"
}

write_legacy_config() {
  cat > "$config_file" <<'EOF'
model_provider = "provider_a"
model = "model-a"
model_reasoning_effort = "high"

# BEGIN codex-remote-provider-kit:provider_a
[model_providers.provider_a]
name = "provider_a"
base_url = "https://a.test/v1"
env_key = "PROVIDER_A_KEY"
wire_api = "responses"
# END codex-remote-provider-kit:provider_a

# BEGIN codex-remote-provider-kit:provider_b
[model_providers.provider_b]
name = "provider_b"
base_url = "https://b.test/v1"
env_key = "PROVIDER_B_KEY"
wire_api = "responses"
# END codex-remote-provider-kit:provider_b
EOF
}

write_provider_record "$providers_dir/provider_a.env" provider_a PROVIDER_A_KEY \
  https://a.test/v1 model-a high
write_provider_record "$providers_dir/provider_b.env" provider_b PROVIDER_B_KEY \
  https://b.test/v1 model-b medium
write_secret_environment_file "$provider_secrets_dir/provider_a.env" PROVIDER_A_KEY good_a
write_secret_environment_file "$provider_secrets_dir/provider_b.env" PROVIDER_B_KEY good_b
printf 'model = "model-a"\nmodel_provider = "provider_a"\nmodel_reasoning_effort = "high"\n' \
  > "$codex_home/provider_a.config.toml"
printf 'model = "model-b"\nmodel_provider = "provider_b"\nmodel_reasoning_effort = "medium"\n' \
  > "$codex_home/provider_b.config.toml"
printf '# Managed by codex-remote-provider-kit\n' > "$third_party_unit"
printf '# Managed by codex-remote-provider-kit\n' > "$official_unit"
printf '# Managed by codex-remote-provider-kit\n' > "$command_file"
write_legacy_state
write_legacy_config
write_secret_environment_file "$active_secret_file" PROVIDER_A_KEY good_a

common_env=(
  PATH="$mock_bin:$PATH"
  MOCK_LOG="$mock_log"
  MOCK_ACTIVE_UNIT="$third_party_name"
  MOCK_ENABLED_UNIT="$third_party_name"
  CODEX_RP_STATE_FILE="$state_file"
  CODEX_RP_SECRET_FILE="$active_secret_file"
)

env "${common_env[@]}" bash "$repo_dir/use-third-party.sh" provider_b \
  > "$test_dir/switch.log"
# shellcheck disable=SC1090
source "$state_file"
[[ "$SESSION_PROVIDER_ID" == provider_a ]]
[[ "$PROVIDER_ID" == provider_b ]]
grep -Fq 'model_provider=provider_a' "$third_party_unit"
grep -Fq 'model_provider=provider_a' "$official_unit"
grep -Fxq 'PROVIDER_B_KEY="good_b"' "$active_secret_file"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "provider_a"
assert config["model"] == "model-b"
assert config["model_reasoning_effort"] == "medium"
session = config["model_providers"]["provider_a"]
assert session["base_url"] == "https://b.test/v1"
assert session["env_key"] == "PROVIDER_B_KEY"
PY

write_legacy_state
write_legacy_config
write_secret_environment_file "$provider_secrets_dir/provider_a.env" PROVIDER_A_KEY known_good
printf 'WRONG_KEY="damaged"\n' > "$active_secret_file"
chmod 600 "$active_secret_file"
cp -p "$state_file" "$test_dir/damaged-state-before"
cp -p "$config_file" "$test_dir/damaged-config-before"
cp -p "$providers_dir/provider_a.env" "$test_dir/damaged-record-before"
set +e
env "${common_env[@]}" bash "$repo_dir/use-third-party.sh" provider_b \
  > "$test_dir/damaged-secret.log" 2>&1
damaged_secret_status=$?
set -e
[[ $damaged_secret_status != 0 ]]
grep -Fq '状态或密钥文件无效' "$test_dir/damaged-secret.log"
cmp -s "$state_file" "$test_dir/damaged-state-before"
cmp -s "$config_file" "$test_dir/damaged-config-before"
cmp -s "$providers_dir/provider_a.env" "$test_dir/damaged-record-before"
grep -Fxq 'PROVIDER_A_KEY="known_good"' "$provider_secrets_dir/provider_a.env"

printf 'legacy session upgrade and registry validation: ok\n'
