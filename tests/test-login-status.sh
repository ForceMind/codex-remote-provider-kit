#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"

test_dir=$(mktemp -d)
mock_codex="$test_dir/codex"
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ "$*" == "login status" ]] || exit 2' \
  'printf "Logged in using ChatGPT\n" >&2' > "$mock_codex"
chmod 755 "$mock_codex"
is_chatgpt_logged_in "$mock_codex"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "Logged in using an API key\n"' > "$mock_codex"
chmod 755 "$mock_codex"
if is_chatgpt_logged_in "$mock_codex"; then
  printf 'API-key login was incorrectly accepted\n' >&2
  exit 1
fi

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exit 1' > "$mock_codex"
chmod 755 "$mock_codex"
if is_chatgpt_logged_in "$mock_codex"; then
  printf 'failed login status was incorrectly accepted\n' >&2
  exit 1
fi

printf 'ChatGPT login status detection: ok\n'
