#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"

test_dir=$(mktemp -d)
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

fake_real_codex="$test_dir/fake-real-codex"
cat > "$fake_real_codex" <<'EOF'
#!/usr/bin/env bash
printf 'ran:%s:THIRD_PARTY_API_KEY=%s\n' "$*" "${THIRD_PARTY_API_KEY-<unset>}"
EOF
chmod 755 "$fake_real_codex"
secret_file="$test_dir/provider.env"
printf 'THIRD_PARTY_API_KEY="s3cret"\n' > "$secret_file"

block_file="$test_dir/block"
write_codex_shell_wrapper_block "$block_file" "$fake_real_codex" "$secret_file" fake-unit.service
grep -Fxq '# BEGIN codex-remote-provider-kit:shell-integration' "$block_file"
grep -Fxq '# END codex-remote-provider-kit:shell-integration' "$block_file"
bash -n "$block_file"

# Behavior: injects the key only while the third-party unit is active, and
# never leaks it into the invoking shell itself.
(
  source "$block_file"
  systemctl() { [[ "$1 $2 $3" == 'is-active --quiet fake-unit.service' ]]; }
  [[ $(codex exec ping) == 'ran:exec ping:THIRD_PARTY_API_KEY=s3cret' ]]
  [[ -z "${THIRD_PARTY_API_KEY-}" ]]

  systemctl() { return 1; }
  [[ $(codex exec ping) == 'ran:exec ping:THIRD_PARTY_API_KEY=<unset>' ]]
)

# Behavior: falls back to running the real binary directly (official-mode
# behavior) when the secret file is missing, even if the unit reports active
# (e.g. mid-rollback).
(
  source "$block_file"
  systemctl() { return 0; }
  rm -f "$secret_file"
  [[ $(codex exec ping) == 'ran:exec ping:THIRD_PARTY_API_KEY=<unset>' ]]
)
printf 'THIRD_PARTY_API_KEY="s3cret"\n' > "$secret_file"

# render_codex_shell_wrapper_rc: preserves unrelated content, is idempotent
# across repeated installs/refreshes, and updates in place when inputs change.
rc_file="$test_dir/bashrc"
printf 'alias ll="ls -la"\nexport FOO=bar\n' > "$rc_file"

rendered1="$test_dir/rendered1"
render_codex_shell_wrapper_rc "$rc_file" "$rendered1" "$fake_real_codex" "$secret_file" unit-a.service
grep -Fxq 'alias ll="ls -la"' "$rendered1"
grep -Fxq 'export FOO=bar' "$rendered1"
grep -Fq 'unit-a.service' "$rendered1"
bash -n "$rendered1"

rendered2="$test_dir/rendered2"
render_codex_shell_wrapper_rc "$rendered1" "$rendered2" "$fake_real_codex" "$secret_file" unit-b.service
[[ $(grep -c '# BEGIN codex-remote-provider-kit:shell-integration' "$rendered2") == 1 ]]
grep -Fq 'unit-b.service' "$rendered2"
if grep -Fq 'unit-a.service' "$rendered2"; then
  printf 're-render left a stale unit reference behind\n' >&2
  exit 1
fi
grep -Fxq 'alias ll="ls -la"' "$rendered2"
grep -Fxq 'export FOO=bar' "$rendered2"

rendered3="$test_dir/rendered3"
render_codex_shell_wrapper_rc "$rendered2" "$rendered3" "$fake_real_codex" "$secret_file" unit-b.service
cmp -s "$rendered2" "$rendered3"

# render_codex_shell_wrapper_rc: works when the rc file does not exist yet.
fresh_rc="$test_dir/missing-bashrc"
rendered_fresh="$test_dir/rendered-fresh"
render_codex_shell_wrapper_rc "$fresh_rc" "$rendered_fresh" "$fake_real_codex" "$secret_file" unit-a.service
grep -Fxq '# BEGIN codex-remote-provider-kit:shell-integration' "$rendered_fresh"
bash -n "$rendered_fresh"

# remove_codex_shell_wrapper_block: strips only the managed block.
removable_rc="$test_dir/removable-bashrc"
cp "$rendered2" "$removable_rc"
remove_codex_shell_wrapper_block "$removable_rc"
grep -Fxq 'alias ll="ls -la"' "$removable_rc"
grep -Fxq 'export FOO=bar' "$removable_rc"
if grep -Fq 'codex-remote-provider-kit:shell-integration' "$removable_rc"; then
  printf 'shell wrapper block was not removed\n' >&2
  exit 1
fi

# remove_codex_shell_wrapper_block: a no-op on a file without our block, and
# safe to call when the file does not exist at all.
untouched_rc="$test_dir/untouched-bashrc"
printf 'export ONLY=here\n' > "$untouched_rc"
remove_codex_shell_wrapper_block "$untouched_rc"
grep -Fxq 'export ONLY=here' "$untouched_rc"
remove_codex_shell_wrapper_block "$test_dir/does-not-exist"

printf 'shell integration: ok\n'
