#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"

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

printf 'API key validation: ok\n'
