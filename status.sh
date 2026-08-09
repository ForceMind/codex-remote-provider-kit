#!/usr/bin/env bash
set -euo pipefail

full='no'
[[ ${1-} == '--full' ]] && full='yes'
state_file='/var/lib/codex-remote-provider/state.env'
secret_file='/etc/codex-remote-provider/provider.env'
[[ -r "$state_file" ]] || { printf '缺少状态文件：%s\n' "$state_file" >&2; exit 1; }
[[ -r "$secret_file" ]] || { printf '缺少密钥文件：%s\n' "$secret_file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"
set -a
# shellcheck disable=SC1090
source "$secret_file"
set +a

printf '[服务状态]\n'
systemctl show codex-remote-provider.service \
  -p ActiveState -p SubState -p Result -p UnitFileState --no-pager
[[ $(systemctl is-enabled codex-remote-provider.service) == enabled ]]
[[ $(systemctl is-active codex-remote-provider.service) == active ]]

printf '[Codex 状态]\n'
"$CODEX_BIN_PATH" --version
login_status=$("$CODEX_BIN_PATH" login status 2>&1) || {
  printf '无法读取 Codex 登录状态，原始输出如下：\n' >&2
  printf '%s\n' "$login_status" >&2
  exit 1
}
if [[ "$login_status" == *'Logged in using ChatGPT'* ]]; then
  printf '登录状态：已使用 ChatGPT 登录\n'
else
  printf '登录状态异常，原始输出如下：\n' >&2
  printf '%s\n' "$login_status" >&2
  exit 1
fi

printf '[配置检查]\n'
python3 - "$CODEX_HOME_DIR/config.toml" "$CODEX_HOME_DIR/$PROVIDER_ID.config.toml" \
  "$PROVIDER_ID" "$MODEL" "$REASONING" <<'PY'
import sys, tomllib
for path in sys.argv[1:3]:
    with open(path, "rb") as handle:
        tomllib.load(handle)
    print(f"通过：{path}")
with open(sys.argv[1], "rb") as handle:
    user_config = tomllib.load(handle)
expected = {
    "model_provider": sys.argv[3],
    "model": sys.argv[4],
    "model_reasoning_effort": sys.argv[5],
}
for key, wanted in expected.items():
    actual = user_config.get(key)
    if actual != wanted:
        raise SystemExit(f"默认配置 {key} 不匹配：应为 {wanted}，实际为 {actual!r}")
    print(f"默认配置 {key}：{actual}")
PY

printf '[模型列表接口]\n'
http_code=$(curl --silent --show-error --output /dev/null --max-time 20 \
  --write-out '%{http_code}' "$BASE_URL/models" \
  -H "Authorization: Bearer ${!ENV_NAME}")
printf 'HTTP 状态码：%s\n' "$http_code"
[[ "$http_code" == 200 ]] || exit 1

if [[ "$full" == yes ]]; then
  response_file=$(mktemp)
  last_message=$(mktemp)
  codex_log=$(mktemp)
  cleanup() { rm -f "$response_file" "$last_message" "$codex_log"; }
  trap cleanup EXIT

  printf '[响应接口]\n'
  http_code=$(curl --silent --show-error --no-buffer --max-time 90 \
    --output "$response_file" --write-out '%{http_code}' "$BASE_URL/responses" \
    -H "Authorization: Bearer ${!ENV_NAME}" \
    -H 'Content-Type: application/json' \
    --data "{\"model\":\"$MODEL\",\"input\":[{\"role\":\"user\",\"content\":\"Reply exactly OK\"}],\"stream\":true}")
  printf 'HTTP 状态码：%s\n' "$http_code"
  [[ "$http_code" == 200 ]] || { sed -n '1,20p' "$response_file"; exit 1; }
  grep -q 'response.completed' "$response_file" || { printf '缺少 response.completed 事件\n' >&2; exit 1; }

  printf '[Codex 真实回合]\n'
  if ! "$CODEX_BIN_PATH" exec --strict-config --profile "$PROVIDER_ID" --ephemeral \
      --skip-git-repo-check --sandbox read-only -C /tmp \
      --output-last-message "$last_message" 'Do not use tools. Reply exactly OK.' \
      >/dev/null 2>"$codex_log"; then
    printf 'Codex 真实回合失败，原始日志如下：\n' >&2
    sed -n '1,120p' "$codex_log" >&2
    exit 1
  fi
  grep -qx 'OK' "$last_message"
  printf 'Codex 回复：OK\n'
fi
