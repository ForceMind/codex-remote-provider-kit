#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"

((EUID == 0)) || {
  printf 'test-provider-config.sh must run as root to exercise ownership checks\n' >&2
  exit 1
}

test_dir=$(mktemp -d)
config_file="$test_dir/config.toml"
cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT

printf '%s\n' \
  'model = "test-model"' \
  'model_provider = "openai"' \
  '' \
  '[model_providers.third_party]' \
  'base_url = "https://example.invalid/v1"' \
  'env_key = "TEST_PROVIDER_KEY"' \
  'wire_api = "responses"' > "$config_file"

set_default_provider "$config_file" third_party
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "third_party"
assert config["model_providers"]["third_party"]["wire_api"] == "responses"
PY

set_default_provider "$config_file" openai
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "openai"
PY

remove_default_provider "$config_file"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert "model_provider" not in config
PY

empty_config="$test_dir/empty.toml"
: > "$empty_config"
set_remote_defaults "$empty_config" third_party gpt-5.6-sol high
python3 - "$empty_config" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config == {
    "model_provider": "third_party",
    "model": "gpt-5.6-sol",
    "model_reasoning_effort": "high",
}
PY

backup_file="$test_dir/backup.toml"
printf '%s\n' \
  'model = "official-model"' \
  'model_reasoning_effort = "medium"' > "$backup_file"
set_remote_defaults "$config_file" third_party third-party-model high
restore_remote_defaults "$config_file" "$backup_file"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert "model_provider" not in config
assert config["model"] == "official-model"
assert config["model_reasoning_effort"] == "medium"
PY

printf 'provider config switching: ok\n'

stable_config="$test_dir/stable.toml"
cat > "$stable_config" <<'EOF'
model_provider = "stable_session"
model = "third-model"
model_reasoning_effort = "high"

# BEGIN codex-remote-provider-kit:stable_session
[model_providers.stable_session]
name = "stable_session"
base_url = "https://old.test/v1"
env_key = "OLD_KEY"
wire_api = "responses"
# END codex-remote-provider-kit:stable_session
EOF
configure_official_session_provider "$stable_config" stable_session
set_top_level_string "$stable_config" model_provider stable_session
restore_official_model_defaults "$stable_config" "$backup_file"
python3 - "$stable_config" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "stable_session"
assert config["model"] == "official-model"
assert config["model_reasoning_effort"] == "medium"
provider = config["model_providers"]["stable_session"]
assert provider["base_url"] == "https://chatgpt.com/backend-api/codex"
assert provider["requires_openai_auth"] is True
assert "env_key" not in provider
PY
configure_third_party_session_provider \
  "$stable_config" stable_session https://new.test/v1 NEW_KEY
set_remote_defaults "$stable_config" stable_session new-model xhigh
python3 - "$stable_config" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "stable_session"
assert config["model"] == "new-model"
assert config["model_reasoning_effort"] == "xhigh"
provider = config["model_providers"]["stable_session"]
assert provider["base_url"] == "https://new.test/v1"
assert provider["env_key"] == "NEW_KEY"
assert "requires_openai_auth" not in provider
PY
printf 'stable session provider switching: ok\n'

state_file="$test_dir/state.env"
printf 'BASE_URL=%q\nMODEL=%q\n' 'https://old.test/v1' 'old-model' > "$state_file"
set_state_variable "$state_file" BASE_URL 'https://new.test/v1'
set_state_variable "$state_file" REASONING high
# shellcheck disable=SC1090
source "$state_file"
[[ "$BASE_URL" == 'https://new.test/v1' ]]
[[ "$MODEL" == 'old-model' ]]
[[ "$REASONING" == high ]]
set_state_variable "$state_file" MANAGED_PROVIDER_IDS 'provider_a provider_b'
set_state_variable "$state_file" ROUND_TRIP_PATH 'dir\with space'
set_state_variable "$state_file" EMPTY_VALUE ''
(
  unset MANAGED_PROVIDER_IDS ROUND_TRIP_PATH EMPTY_VALUE
  # shellcheck disable=SC1090
  source "$state_file"
  [[ "$MANAGED_PROVIDER_IDS" == 'provider_a provider_b' ]]
  [[ "$ROUND_TRIP_PATH" == 'dir\with space' ]]
  [[ -z "$EMPTY_VALUE" ]]
)
printf 'provider state update: ok\n'

first_id=$(provider_id_from_base_url 'https://gateway.example/v1')
same_id=$(provider_id_from_base_url 'https://gateway.example/v1/')
second_id=$(provider_id_from_base_url 'https://gateway.example/v2')
[[ "$first_id" == "$same_id" && "$first_id" != "$second_id" ]]
[[ "$first_id" =~ ^gateway_example_v1_[a-f0-9]{10}$ ]]
[[ $(provider_env_name_from_id "$first_id") =~ ^CODEX_RP_GATEWAY_EXAMPLE_V1_[A-F0-9]{10}_API_KEY$ ]]
printf 'address-derived provider identity: ok\n'

sync_state="$test_dir/sync-state.env"
sync_secret="$test_dir/sync-secret.env"
sync_records="$test_dir/sync-records"
sync_secrets="$test_dir/sync-secrets"
printf 'PROVIDER_ID=sync_provider\n' > "$sync_state"
printf 'SYNC_KEY="sync_key"\n' > "$sync_secret"
chmod 600 "$sync_state" "$sync_secret"
if (
  PROVIDER_ID=sync_provider
  ENV_NAME=SYNC_KEY
  BASE_URL=https://sync.test/v1
  MODEL=sync-model
  REASONING=medium
  INSTALLED_PROVIDER_ID=sync_provider
  CODEX_RP_PROVIDERS_DIR=$sync_records
  CODEX_RP_PROVIDER_SECRETS_DIR=$sync_secrets
  write_provider_record() { return 1; }
  sync_current_provider_registry "$sync_state" "$sync_secret"
); then
  printf 'registry sync ignored a provider-record write failure\n' >&2
  exit 1
fi
if grep -Eq '^(PROVIDERS_DIR|PROVIDER_SECRETS_DIR)=' "$sync_state"; then
  printf 'failed registry sync updated persistent state\n' >&2
  exit 1
fi
rm -rf "$sync_records" "$sync_secrets"
rm -f "$sync_state" "$sync_secret"
printf 'provider registry failure propagation: ok\n'

broken_record="$test_dir/broken-record.env"
cat > "$broken_record" <<'EOF'
PROVIDER_ID=broken_provider
ENV_NAME=BROKEN_KEY
BASE_URL=https://broken.test/v1
MODEL=broken-model
REASONING=medium
false
EOF
chmod 600 "$broken_record"
if load_provider_record "$broken_record" broken_provider; then
  printf 'provider record loader ignored a source failure\n' >&2
  exit 1
fi
printf 'provider record source failure propagation: ok\n'

untrusted_record="$test_dir/untrusted-record.env"
record_sentinel="$test_dir/record-was-executed"
printf 'PROVIDER_ID=untrusted\nENV_NAME=UNTRUSTED_KEY\nBASE_URL=https://untrusted.test/v1\nMODEL=untrusted-model\nREASONING=medium\n: > %q\n' \
  "$record_sentinel" > "$untrusted_record"
chmod 644 "$untrusted_record"
if load_provider_record "$untrusted_record" untrusted; then
  printf 'provider record loader accepted a non-root-only record\n' >&2
  exit 1
fi
[[ ! -e "$record_sentinel" ]]

untrusted_state="$test_dir/untrusted-state.env"
state_sentinel="$test_dir/state-was-executed"
printf ': > %q\n' "$state_sentinel" > "$untrusted_state"
chmod 644 "$untrusted_state"
set +e
CODEX_RP_STATE_FILE="$untrusted_state" \
  bash "$repo_dir/status.sh" > "$test_dir/untrusted-state.log" 2>&1
untrusted_state_status=$?
set -e
[[ $untrusted_state_status != 0 ]]
[[ ! -e "$state_sentinel" ]]
printf 'root-only state and record parsing: ok\n'

profile_fixture="$test_dir/provider-profile.toml"
printf 'model_provider = "profile_provider"\nmodel = "profile-model"\nmodel_reasoning_effort = "high"\n' \
  > "$profile_fixture"
if provider_profile_matches "$profile_fixture" profile_provider profile-model high yes; then
  printf 'marker-required profile validation accepted an unmarked file\n' >&2
  exit 1
fi
provider_profile_matches "$profile_fixture" profile_provider profile-model high no
printf '# Managed by codex-remote-provider-kit:profile_provider\nmodel_provider = "profile_provider"\nmodel = "profile-model"\nmodel_reasoning_effort = "high"\nextra = "foreign"\n' \
  > "$profile_fixture"
if provider_profile_matches "$profile_fixture" profile_provider profile-model high yes; then
  printf 'profile validation accepted an extra foreign field\n' >&2
  exit 1
fi
printf 'provider profile ownership validation: ok\n'

failure_config="$test_dir/failure-propagation.toml"
cp "$stable_config" "$failure_config"
if (
  remove_managed_provider_block() { return 1; }
  configure_third_party_session_provider \
    "$failure_config" stable_session https://failure.test/v1 FAILURE_KEY
); then
  printf 'third-party provider helper ignored a block-removal failure\n' >&2
  exit 1
fi
if (
  remove_managed_provider_block() { return 1; }
  configure_official_session_provider "$failure_config" stable_session
); then
  printf 'official provider helper ignored a block-removal failure\n' >&2
  exit 1
fi

if (
  default_write_count=0
  set_top_level_string() {
    default_write_count=$((default_write_count + 1))
    ((default_write_count != 1))
  }
  set_remote_defaults "$failure_config" stable_session failure-model high
); then
  printf 'remote defaults helper ignored an intermediate write failure\n' >&2
  exit 1
fi

if (
  restore_write_count=0
  remove_top_level_key() { return 0; }
  set_top_level_string() {
    restore_write_count=$((restore_write_count + 1))
    ((restore_write_count != 1))
  }
  restore_remote_defaults "$failure_config" "$backup_file"
); then
  printf 'remote defaults restore ignored an intermediate write failure\n' >&2
  exit 1
fi
if (
  restore_write_count=0
  set_top_level_string() {
    restore_write_count=$((restore_write_count + 1))
    ((restore_write_count != 1))
  }
  restore_official_model_defaults "$failure_config" "$backup_file"
); then
  printf 'official defaults restore ignored an intermediate write failure\n' >&2
  exit 1
fi

cp "$stable_config" "$failure_config"
if (
  install() { return 1; }
  remove_managed_provider_block "$failure_config" stable_session
); then
  printf 'provider block removal ignored an install failure\n' >&2
  exit 1
fi
if (
  install() { return 1; }
  set_top_level_string "$failure_config" model failure-model
); then
  printf 'top-level setter ignored an install failure\n' >&2
  exit 1
fi
if (
  install() { return 1; }
  remove_top_level_key "$failure_config" model
); then
  printf 'top-level remover ignored an install failure\n' >&2
  exit 1
fi
printf 'configuration helper failure propagation: ok\n'

record_parent="$test_dir/record-parent"
mkdir "$record_parent"
chmod 1777 "$record_parent"
record_parent_before=$(stat -c '%u:%g:%a' "$record_parent")
write_provider_record "$record_parent/provider.env" parent_test PARENT_KEY \
  https://parent.test/v1 parent-model medium
record_parent_after=$(stat -c '%u:%g:%a' "$record_parent")
[[ "$record_parent_after" == "$record_parent_before" ]]
printf 'provider record writer preserves parent metadata: ok\n'

failed_record="$test_dir/failed-provider-record.env"
if (
  printf_call_count=0
  printf() {
    printf_call_count=$((printf_call_count + 1))
    ((printf_call_count != 3)) || return 1
    builtin printf "$@"
  }
  write_provider_record "$failed_record" failed_provider FAILED_KEY \
    https://failed.test/v1 failed-model medium
); then
  printf 'provider record writer ignored an intermediate printf failure\n' >&2
  exit 1
fi
[[ ! -e "$failed_record" ]]
printf 'provider record intermediate failure propagation: ok\n'
