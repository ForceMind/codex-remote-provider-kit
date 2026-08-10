#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"

test_dir=$(mktemp -d)
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

for valid_key in \
  'sk-example_123-ABC' \
  'c29tZS1vcGFxdWUtdG9rZW4=' \
  'part.one~part/two+three=='; do
  is_supported_api_key "$valid_key"
done

for invalid_key in \
  '' \
  ' leading-space' \
  'trailing-space ' \
  'quoted"key' \
  'backslash\key' \
  $'line\r' \
  $'two\nlines'; do
  if is_supported_api_key "$invalid_key"; then
    printf 'invalid API key format was accepted\n' >&2
    exit 1
  fi
done

secret_file="$test_dir/provider.env"
write_secret_environment_file "$secret_file" TEST_PROVIDER_KEY '~'
[[ $(stat -c '%a' "$secret_file") == 600 ]]
unset TEST_PROVIDER_KEY
# shellcheck disable=SC1090
source "$secret_file"
[[ "$TEST_PROVIDER_KEY" == '~' ]]
unset TEST_PROVIDER_KEY
read_secret_environment_value "$secret_file" TEST_PROVIDER_KEY
[[ "$CODEX_RP_SECRET_VALUE" == '~' ]]

printf 'TEST_PROVIDER_KEY=legacy_value\n' > "$secret_file"
read_secret_environment_value "$secret_file" TEST_PROVIDER_KEY
[[ "$CODEX_RP_SECRET_VALUE" == 'legacy_value' ]]

execution_marker="$test_dir/should-not-exist"
printf 'TEST_PROVIDER_KEY=$(touch %s)\n' "$execution_marker" > "$secret_file"
if read_secret_environment_value "$secret_file" TEST_PROVIDER_KEY; then
  printf 'executable secret-file syntax was accepted\n' >&2
  exit 1
fi
[[ ! -e "$execution_marker" ]]

if write_secret_environment_file "$secret_file" 'BAD-NAME' 'valid_value' 2>/dev/null; then
  printf 'invalid environment name was accepted\n' >&2
  exit 1
fi

printf 'API key validation: ok\n'
