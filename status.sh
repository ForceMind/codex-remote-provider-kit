#!/usr/bin/env bash
set -euo pipefail

full='no'
[[ ${1-} == '--full' ]] && full='yes'
state_file='/var/lib/codex-remote-provider/state.env'
secret_file='/etc/codex-remote-provider/provider.env'
[[ -r "$state_file" ]] || { printf 'state file missing: %s\n' "$state_file" >&2; exit 1; }
[[ -r "$secret_file" ]] || { printf 'secret file missing: %s\n' "$secret_file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"
set -a
# shellcheck disable=SC1090
source "$secret_file"
set +a

printf '[service]\n'
systemctl show codex-remote-provider.service \
  -p ActiveState -p SubState -p Result -p UnitFileState --no-pager

printf '[codex]\n'
"$CODEX_BIN_PATH" --version
"$CODEX_BIN_PATH" login status

printf '[config]\n'
python3 - "$CODEX_HOME_DIR/config.toml" "$CODEX_HOME_DIR/$PROVIDER_ID.config.toml" "$PROVIDER_ID" <<'PY'
import sys, tomllib
for path in sys.argv[1:3]:
    with open(path, "rb") as handle:
        tomllib.load(handle)
    print(f"ok: {path}")
with open(sys.argv[1], "rb") as handle:
    user_config = tomllib.load(handle)
actual = user_config.get("model_provider")
expected = sys.argv[3]
if actual != expected:
    raise SystemExit(f"default model_provider mismatch: expected {expected}, got {actual!r}")
print(f"default model_provider: {actual}")
PY

printf '[models_endpoint]\n'
http_code=$(curl --silent --show-error --output /dev/null --max-time 20 \
  --write-out '%{http_code}' "$BASE_URL/models" \
  -H "Authorization: Bearer ${!ENV_NAME}")
printf 'HTTP %s\n' "$http_code"
[[ "$http_code" == 200 ]] || exit 1

if [[ "$full" == yes ]]; then
  response_file=$(mktemp)
  last_message=$(mktemp)
  cleanup() { rm -f "$response_file" "$last_message"; }
  trap cleanup EXIT

  printf '[responses_endpoint]\n'
  http_code=$(curl --silent --show-error --no-buffer --max-time 90 \
    --output "$response_file" --write-out '%{http_code}' "$BASE_URL/responses" \
    -H "Authorization: Bearer ${!ENV_NAME}" \
    -H 'Content-Type: application/json' \
    --data "{\"model\":\"$MODEL\",\"input\":[{\"role\":\"user\",\"content\":\"Reply exactly OK\"}],\"stream\":true}")
  printf 'HTTP %s\n' "$http_code"
  [[ "$http_code" == 200 ]] || { sed -n '1,20p' "$response_file"; exit 1; }
  grep -q 'response.completed' "$response_file" || { printf 'missing response.completed event\n' >&2; exit 1; }

  printf '[codex_turn]\n'
  "$CODEX_BIN_PATH" exec --strict-config --profile "$PROVIDER_ID" --ephemeral \
    --skip-git-repo-check --sandbox read-only -C /tmp \
    --output-last-message "$last_message" 'Do not use tools. Reply exactly OK.' >/dev/null
  grep -qx 'OK' "$last_message"
  printf 'Codex response: OK\n'
fi
