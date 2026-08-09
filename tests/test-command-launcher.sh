#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"

test_dir=$(mktemp -d)
fake_setup="$test_dir/setup script.sh"
launcher="$test_dir/codex-remote-provider"
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "called:%s\n" "$*"' > "$fake_setup"
chmod 755 "$fake_setup"

write_command_launcher "$launcher" "$fake_setup"
[[ -x "$launcher" ]]
grep -Fxq '# Managed by codex-remote-provider-kit' "$launcher"
[[ $(cd /tmp && "$launcher") == 'called:menu' ]]

printf 'global command launcher: ok\n'
