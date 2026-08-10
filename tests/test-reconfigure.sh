#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_dir=$(mktemp -d)
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT
mock_bin="$test_dir/bin"
codex_home="$test_dir/codex-home"
mkdir -p "$mock_bin" "$codex_home"
cat > "$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case ${1-} in is-active|is-enabled) exit 1 ;; esac
exit 0
EOF
chmod 755 "$mock_bin/systemctl"

state_file="$test_dir/state.env"
secret_file="$test_dir/provider.env"
third_party_unit="$test_dir/codex-remote-provider.service"
official_unit="$test_dir/codex-remote-official.service"
command_file="$test_dir/codex-rp"
config_file="$codex_home/config.toml"
profile_file="$codex_home/third_party.config.toml"
cat > "$config_file" <<'EOF'
model_provider = "third_party"
model = "old-model"
model_reasoning_effort = "high"

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
{
  printf 'PROVIDER_ID=%q\n' third_party
  printf 'ENV_NAME=%q\n' TEST_KEY
  printf 'BASE_URL=%q\n' https://old.test/v1
  printf 'MODEL=%q\n' old-model
  printf 'REASONING=%q\n' high
  printf 'CODEX_HOME_DIR=%q\n' "$codex_home"
  printf 'CODEX_BIN_PATH=%q\n' /usr/bin/false
  printf 'COMMAND_FILE=%q\n' "$command_file"
  printf 'BACKUP_DIR=%q\n' "$test_dir/backup"
  printf 'THIRD_PARTY_UNIT_FILE=%q\n' "$third_party_unit"
  printf 'OFFICIAL_UNIT_FILE=%q\n' "$official_unit"
} > "$state_file"
chmod 600 "$state_file"
common_env=(PATH="$mock_bin:$PATH" CODEX_RP_STATE_FILE="$state_file" CODEX_RP_SECRET_FILE="$secret_file")

printf 'https://new.test/v1\nnew-model\nmedium\n\n' | env "${common_env[@]}" \
  bash "$repo_dir/reconfigure.sh" > "$test_dir/reconfigure.log"
python3 - "$config_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config["model"] == "new-model"
assert config["model_reasoning_effort"] == "medium"
assert config["model_providers"]["third_party"]["base_url"] == "https://new.test/v1"
PY
# shellcheck disable=SC1090
source "$state_file"
[[ "$BASE_URL" == https://new.test/v1 && "$MODEL" == new-model && "$REASONING" == medium ]]
grep -Fxq 'TEST_KEY="old_key"' "$secret_file"

printf 'new_key==\n' | env "${common_env[@]}" \
  bash "$repo_dir/reconfigure.sh" --key-only > "$test_dir/rotate.log"
grep -Fxq 'TEST_KEY="new_key=="' "$secret_file"
grep -Fq '内容已隐藏' "$test_dir/rotate.log"
if grep -Fq 'new_key==' "$test_dir/rotate.log"; then
  printf 'rotated key was printed\n' >&2
  exit 1
fi
printf 'provider reconfiguration and key rotation: ok\n'
