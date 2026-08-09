#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"

test_dir=$(mktemp -d)
fake_setup="$test_dir/setup script.sh"
launcher="$test_dir/codex-rp"
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

managed_command="$test_dir/managed-command"
install_global_command "$fake_setup" "$managed_command"
[[ $(cd / && "$managed_command") == 'called:menu' ]]

unmanaged_command="$test_dir/unmanaged-command"
printf '#!/usr/bin/env bash\n' > "$unmanaged_command"
if install_global_command "$fake_setup" "$unmanaged_command" 2>/dev/null; then
  printf 'unmanaged command was overwritten\n' >&2
  exit 1
fi

printf 'global command launcher: ok\n'
