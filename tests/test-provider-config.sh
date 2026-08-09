#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"

test_dir=$(mktemp -d)
config_file="$test_dir/config.toml"
cleanup() {
  rm -f "$config_file" "$test_dir/backup.toml"
  rmdir "$test_dir"
}
trap cleanup EXIT

printf '%s\n' \
  'model = "test-model"' \
  'model_provider = "openai"' \
  '' \
  '[model_providers.inno_flare]' \
  'base_url = "https://example.invalid/v1"' \
  'env_key = "TEST_PROVIDER_KEY"' \
  'wire_api = "responses"' > "$config_file"

set_default_provider "$config_file" inno_flare
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model_provider"] == "inno_flare"
assert config["model_providers"]["inno_flare"]["wire_api"] == "responses"
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

backup_file="$test_dir/backup.toml"
printf '%s\n' \
  'model = "official-model"' \
  'model_reasoning_effort = "medium"' > "$backup_file"
set_remote_defaults "$config_file" inno_flare third-party-model high
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
