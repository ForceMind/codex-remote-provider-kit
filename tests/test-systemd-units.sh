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
  grep -Fxq 'TimeoutStopSec=30s' "$unit"
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
mock_start_attempts=0
mock_start_failures=0
mock_reset_failed=0
systemctl() {
  if [[ ${1-} == --quiet && ${2-} == start ]]; then
    ((mock_start_attempts += 1))
    if ((mock_start_failures > 0)); then
      ((mock_start_failures -= 1))
      return 1
    fi
    return 0
  fi
  if [[ ${1-} == reset-failed ]]; then
    mock_reset_failed=1
    return 0
  fi
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

mock_codex="$test_dir/codex"
cat > "$mock_codex" <<EOF
#!/usr/bin/env bash
printf 'codex:%s\\n' "\$*" >> "$test_dir/codex.log"
EOF
chmod 755 "$mock_codex"
mock_active_state=active
mock_result=success
mock_start_attempts=0
mock_start_failures=1
mock_reset_failed=0
start_remote_systemd_unit "$mock_codex" codex-remote-official.service \
  > "$test_dir/recovery.log" 2>&1
[[ $mock_start_attempts == 2 ]]
[[ $mock_reset_failed == 1 ]]
grep -Fq 'remote-control stop --json' "$test_dir/codex.log"
grep -Fq '正在停止残留 daemon，并重试一次同一模式' \
  "$test_dir/recovery.log"

printf 'systemd unit generation: ok\n'
