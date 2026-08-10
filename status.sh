#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

full='no'
case $# in
  0) ;;
  1)
    [[ $1 == '--full' ]] || {
      printf '错误：未知参数：%s\n' "$1" >&2
      exit 2
    }
    full='yes'
    ;;
  *)
    printf '错误：status.sh 只接受一个可选参数 --full\n' >&2
    exit 2
    ;;
esac

state_file=${CODEX_RP_STATE_FILE:-/var/lib/codex-remote-provider/state.env}
secret_file=${CODEX_RP_SECRET_FILE:-/etc/codex-remote-provider/provider.env}
[[ -r "$state_file" ]] || { printf '缺少状态文件：%s\n' "$state_file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"

third_party_unit_file=${THIRD_PARTY_UNIT_FILE:-/etc/systemd/system/codex-remote-provider.service}
official_unit_file=${OFFICIAL_UNIT_FILE:-/etc/systemd/system/codex-remote-official.service}
third_party_unit_name=${third_party_unit_file##*/}
official_unit_name=${official_unit_file##*/}

third_party_active='no'
official_active='no'
systemctl is-active "$third_party_unit_name" >/dev/null 2>&1 && third_party_active='yes'
systemctl is-active "$official_unit_name" >/dev/null 2>&1 && official_active='yes'

if [[ "$third_party_active" == yes && "$official_active" == yes ]]; then
  printf '错误：第三方和官方 Remote service 同时处于 active 状态\n' >&2
  exit 1
elif [[ "$third_party_active" == yes ]]; then
  mode='third-party'
  selected_unit_name=$third_party_unit_name
elif [[ "$official_active" == yes ]]; then
  mode='official'
  selected_unit_name=$official_unit_name
else
  printf '错误：第三方和官方 Remote service 均未运行\n' >&2
  exit 1
fi

printf '[服务状态]\n'
printf '当前模式：%s\n' "$mode"
systemctl show "$selected_unit_name" \
  -p ActiveState -p SubState -p Result -p UnitFileState --no-pager
[[ $(systemctl is-enabled "$selected_unit_name") == enabled ]]

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
  "$PROVIDER_ID" "$MODEL" "$REASONING" "$mode" "$BACKUP_DIR/config.toml" <<'PY'
import pathlib, sys, tomllib

config_path = pathlib.Path(sys.argv[1])
profile_path = pathlib.Path(sys.argv[2])
mode = sys.argv[6]
backup_path = pathlib.Path(sys.argv[7])

with config_path.open("rb") as handle:
    user_config = tomllib.load(handle)
print(f"通过：{config_path}")

keys = ("model_provider", "model", "model_reasoning_effort")
if mode == "third-party":
    with profile_path.open("rb") as handle:
        tomllib.load(handle)
    print(f"通过：{profile_path}")
    expected = {
        "model_provider": sys.argv[3],
        "model": sys.argv[4],
        "model_reasoning_effort": sys.argv[5],
    }
    for key, wanted in expected.items():
        actual = user_config.get(key)
        if actual != wanted:
            raise SystemExit(
                f"默认配置 {key} 不匹配：应为 {wanted}，实际为 {actual!r}"
            )
        print(f"默认配置 {key}：{actual}")
else:
    if backup_path.is_file():
        with backup_path.open("rb") as handle:
            original = tomllib.load(handle)
    else:
        original = {}
    for key in keys:
        if key in original:
            if user_config.get(key) != original[key]:
                raise SystemExit(
                    f"官方模式配置 {key} 未恢复：应为 {original[key]!r}，"
                    f"实际为 {user_config.get(key)!r}"
                )
            print(f"已恢复 {key}：{original[key]}")
        elif key in user_config:
            raise SystemExit(f"官方模式配置 {key} 应当不存在，实际为 {user_config[key]!r}")
        else:
            print(f"已恢复 {key}：未设置")
PY

if [[ "$mode" == official ]]; then
  if [[ "$full" == yes ]]; then
    printf '[完整测试]\n'
    printf '官方模式不会自动生成模型回复，以避免意外消耗官方额度。\n'
  fi
  exit 0
fi

[[ -r "$secret_file" ]] || { printf '缺少密钥文件：%s\n' "$secret_file" >&2; exit 1; }
if ! read_secret_environment_value "$secret_file" "$ENV_NAME"; then
  printf '密钥文件格式无效：应只包含一行 %s="<密钥>"\n' "$ENV_NAME" >&2
  exit 1
fi
api_key=$CODEX_RP_SECRET_VALUE
printf -v "$ENV_NAME" '%s' "$api_key"
export "$ENV_NAME"
temporary_files=()
cleanup() { rm -f "${temporary_files[@]}"; }
trap cleanup EXIT
auth_header_file=$(mktemp)
temporary_files+=("$auth_header_file")
chmod 600 "$auth_header_file"
printf 'Authorization: Bearer %s\n' "$api_key" > "$auth_header_file"

printf '[模型列表接口]\n'
http_code=$(curl --silent --show-error --output /dev/null --max-time 20 \
  --write-out '%{http_code}' "$BASE_URL/models" \
  -H "@$auth_header_file")
printf 'HTTP 状态码：%s\n' "$http_code"
[[ "$http_code" == 200 ]] || exit 1

if [[ "$full" == yes ]]; then
  response_file=$(mktemp)
  last_message=$(mktemp)
  codex_log=$(mktemp)
  temporary_files+=("$response_file" "$last_message" "$codex_log")

  printf '[响应接口]\n'
  http_code=$(curl --silent --show-error --no-buffer --max-time 90 \
    --output "$response_file" --write-out '%{http_code}' "$BASE_URL/responses" \
    -H "@$auth_header_file" \
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
