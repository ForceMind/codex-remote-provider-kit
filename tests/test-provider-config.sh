#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"

test_dir=$(mktemp -d)
config_file="$test_dir/config.toml"
cleanup() {
  rm -f "$config_file" "$test_dir/backup.toml" "$test_dir/empty.toml" "$test_dir/state.env"
  rmdir "$test_dir"
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

state_file="$test_dir/state.env"
printf 'BASE_URL=%q\nMODEL=%q\n' 'https://old.test/v1' 'old-model' > "$state_file"
set_state_variable "$state_file" BASE_URL 'https://new.test/v1'
set_state_variable "$state_file" REASONING high
# shellcheck disable=SC1090
source "$state_file"
[[ "$BASE_URL" == 'https://new.test/v1' ]]
[[ "$MODEL" == 'old-model' ]]
[[ "$REASONING" == high ]]
printf 'provider state update: ok\n'
