#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../lib.sh
source "$repo_dir/lib.sh"

test_dir=$(mktemp -d)
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

third_party_unit="$test_dir/codex-remote-provider.service"
official_unit="$test_dir/codex-remote-official.service"

write_third_party_unit "$third_party_unit" /usr/local/bin/codex \
  /etc/codex-remote-provider/provider.env third_party gpt-5.6-sol high
write_official_unit "$official_unit" /usr/local/bin/codex

for unit in "$third_party_unit" "$official_unit"; do
  grep -Fxq '# Managed by codex-remote-provider-kit' "$unit"
  grep -Fxq 'Type=oneshot' "$unit"
  grep -Fxq 'RemainAfterExit=yes' "$unit"
  grep -Fxq 'WantedBy=multi-user.target' "$unit"
done

grep -Fxq 'EnvironmentFile=/etc/codex-remote-provider/provider.env' "$third_party_unit"
grep -Fxq 'ExecStart=/usr/local/bin/codex remote-control start --json -c model_provider=third_party -c model=gpt-5.6-sol -c model_reasoning_effort=high' "$third_party_unit"
if grep -Fq 'EnvironmentFile=' "$official_unit"; then
  printf 'official unit unexpectedly loads the third-party secret\n' >&2
  exit 1
fi
grep -Fxq 'ExecStart=/usr/local/bin/codex remote-control start --json' "$official_unit"

mock_active_state=active
mock_result=success
systemctl() {
  if [[ "$*" == *'--value'* ]]; then
    if [[ "$*" == *'ActiveState'* ]]; then
      printf '%s\n' "$mock_active_state"
    elif [[ "$*" == *'Result'* ]]; then
      printf '%s\n' "$mock_result"
    fi
  else
    printf 'ActiveState=%s\nSubState=exited\nResult=%s\nExecMainStatus=0\n' \
      "$mock_active_state" "$mock_result"
  fi
}

require_active_systemd_unit codex-remote-official.service
mock_active_state=failed
mock_result=exit-code
if require_active_systemd_unit codex-remote-official.service \
    > "$test_dir/failed-unit.log" 2>&1; then
  printf 'failed unit unexpectedly passed the post-start check\n' >&2
  exit 1
fi
grep -Fq '启动后未保持正常状态' "$test_dir/failed-unit.log"
grep -Fq 'journalctl -u codex-remote-official.service' \
  "$test_dir/failed-unit.log"

printf 'systemd unit generation: ok\n'
