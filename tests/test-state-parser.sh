#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"
test_dir=$(mktemp -d)
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT
state_file="$test_dir/state.env"
marker="$test_dir/executed"
{
  printf 'PROVIDER_ID=%q\n' third_party
  printf 'CODEX_HOME_DIR=%q\n' '/tmp/path with spaces'
  printf 'MODEL=%q\n' gpt-5.6-sol
} > "$state_file"
read_codex_rp_state "$state_file"
[[ "$PROVIDER_ID" == third_party ]]
[[ "$CODEX_HOME_DIR" == '/tmp/path with spaces' ]]

printf 'PROVIDER_ID=$(touch %q)\n' "$marker" > "$state_file"
if read_codex_rp_state "$state_file" 2>/dev/null; then
  printf 'executable state syntax was accepted\n' >&2
  exit 1
fi
[[ ! -e "$marker" ]]

printf 'UNKNOWN_FIELD=value\n' > "$state_file"
if read_codex_rp_state "$state_file" 2>/dev/null; then
  printf 'unknown state field was accepted\n' >&2
  exit 1
fi

ln -sf "$state_file" "$test_dir/state-link.env"
if read_codex_rp_state "$test_dir/state-link.env" 2>/dev/null; then
  printf 'state symlink was accepted\n' >&2
  exit 1
fi

printf 'managed state parser: ok\n'
