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
is_root_only_regular_file "$state_file" \
  || { printf '状态文件缺失或类型无效：%s\n' "$state_file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"
session_provider=$(session_provider_id) || {
  printf '错误：稳定会话供应商 ID 无效\n' >&2
  exit 1
}
official_base_url=$(official_codex_base_url) || {
  printf '错误：官方 Codex Base URL 无效\n' >&2
  exit 1
}
resolve_provider_storage "$state_file" "$secret_file"
if [[ -v OWNERSHIP_SCHEMA ]]; then
  load_managed_provider_ids \
    || { printf '错误：供应商所有权清单无效\n' >&2; exit 1; }
else
  CODEX_RP_MANAGED_PROVIDER_IDS=("$PROVIDER_ID")
fi

require_root_only_file() {
  local target_file=${1:?file required}
  local label=${2:?label required}
  local mode owner

  [[ -f "$target_file" && ! -L "$target_file" ]] || {
    printf '缺少%s：%s\n' "$label" "$target_file" >&2
    return 1
  }
  mode=$(stat -c '%a' "$target_file") || return 1
  owner=$(stat -c '%u' "$target_file") || return 1
  [[ "$mode" == 600 && "$owner" == 0 ]] || {
    printf '%s必须由 root 拥有且权限为 0600：%s（当前 owner=%s mode=%s）\n' \
      "$label" "$target_file" "$owner" "$mode" >&2
    return 1
  }
}

require_root_only_dir_if_present() {
  local target_dir=${1:?directory required}
  local label=${2:?label required}
  local mode owner

  [[ -e "$target_dir" ]] || return 0
  [[ -d "$target_dir" && ! -L "$target_dir" ]] || {
    printf '%s不是目录：%s\n' "$label" "$target_dir" >&2
    return 1
  }
  mode=$(stat -c '%a' "$target_dir") || return 1
  owner=$(stat -c '%u' "$target_dir") || return 1
  [[ "$mode" == 700 && "$owner" == 0 ]] || {
    printf '%s必须由 root 拥有且权限为 0700：%s（当前 owner=%s mode=%s）\n' \
      "$label" "$target_dir" "$owner" "$mode" >&2
    return 1
  }
}

require_root_only_file "$state_file" '状态文件'
require_root_only_file "$secret_file" '活动密钥文件'
require_root_only_dir_if_present "$CODEX_RP_PROVIDERS_PATH" '供应商记录目录'
require_root_only_dir_if_present "$CODEX_RP_PROVIDER_SECRETS_PATH" '供应商密钥目录'
for managed_provider_id in "${CODEX_RP_MANAGED_PROVIDER_IDS[@]}"; do
  provider_record_file=$(provider_record_path \
    "$CODEX_RP_PROVIDERS_PATH" "$managed_provider_id")
  provider_secret_file=$(provider_secret_path \
    "$CODEX_RP_PROVIDER_SECRETS_PATH" "$managed_provider_id")
  if [[ ${OWNERSHIP_SCHEMA:-} == 1 ]]; then
    require_root_only_file "$provider_record_file" '供应商记录文件'
    require_root_only_file "$provider_secret_file" '供应商密钥文件'
  else
    [[ ! -e "$provider_record_file" ]] \
      || require_root_only_file "$provider_record_file" '供应商记录文件'
    [[ ! -e "$provider_secret_file" ]] \
      || require_root_only_file "$provider_secret_file" '供应商密钥文件'
  fi
done

third_party_unit_file=${THIRD_PARTY_UNIT_FILE:-/etc/systemd/system/codex-remote-provider.service}
official_unit_file=${OFFICIAL_UNIT_FILE:-/etc/systemd/system/codex-remote-official.service}
third_party_unit_name=${third_party_unit_file##*/}
official_unit_name=${official_unit_file##*/}

third_party_active='no'
official_active='no'
third_party_enabled='no'
official_enabled='no'
systemctl is-active "$third_party_unit_name" >/dev/null 2>&1 && third_party_active='yes'
systemctl is-active "$official_unit_name" >/dev/null 2>&1 && official_active='yes'
systemctl is-enabled "$third_party_unit_name" >/dev/null 2>&1 && third_party_enabled='yes'
systemctl is-enabled "$official_unit_name" >/dev/null 2>&1 && official_enabled='yes'

if [[ "$third_party_active" == yes && "$official_active" == yes ]] \
    || [[ "$third_party_enabled" == yes && "$official_enabled" == yes ]]; then
  printf '错误：第三方和官方 Remote service 状态冲突（同时 active 或 enabled）\n' >&2
  exit 1
elif [[ "$third_party_active" == yes ]]; then
  [[ "$third_party_enabled" == yes && "$official_enabled" == no ]] || {
    printf '错误：第三方 Remote 正在运行，但 systemd 启用状态不匹配\n' >&2
    exit 1
  }
  mode='third-party'
  selected_unit_name=$third_party_unit_name
elif [[ "$official_active" == yes ]]; then
  [[ "$official_enabled" == yes && "$third_party_enabled" == no ]] || {
    printf '错误：官方 Remote 正在运行，但 systemd 启用状态不匹配\n' >&2
    exit 1
  }
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
printf '当前供应商：%s\n' "$PROVIDER_ID"
printf '稳定会话供应商：%s\n' "$session_provider"
printf '当前地址：%s\n' "$BASE_URL"
printf '已保存供应商：%d 个\n' "${#CODEX_RP_MANAGED_PROVIDER_IDS[@]}"
python3 - "$CODEX_HOME_DIR/config.toml" "$CODEX_HOME_DIR/$PROVIDER_ID.config.toml" \
  "$session_provider" "$MODEL" "$REASONING" "$mode" "$BACKUP_DIR/config.toml" \
  "$BASE_URL" "$ENV_NAME" "$official_base_url" <<'PY'
import pathlib, sys, tomllib

config_path = pathlib.Path(sys.argv[1])
profile_path = pathlib.Path(sys.argv[2])
mode = sys.argv[6]
backup_path = pathlib.Path(sys.argv[7])
base_url = sys.argv[8]
env_name = sys.argv[9]
official_base_url = sys.argv[10]

with config_path.open("rb") as handle:
    user_config = tomllib.load(handle)
print(f"通过：{config_path}")

session_provider = sys.argv[3]
if user_config.get("model_provider") != session_provider:
    raise SystemExit(
        f"默认配置 model_provider 不匹配：应为 {session_provider}，"
        f"实际为 {user_config.get('model_provider')!r}"
    )
print(f"默认配置 model_provider：{session_provider}")

provider = user_config.get("model_providers", {}).get(session_provider)
if not isinstance(provider, dict):
    raise SystemExit(f"缺少稳定会话供应商配置：{session_provider}")

if mode == "third-party":
    with profile_path.open("rb") as handle:
        tomllib.load(handle)
    print(f"通过：{profile_path}")
    expected = {
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
    if provider.get("base_url", "").rstrip("/") != base_url.rstrip("/"):
        raise SystemExit("稳定会话供应商 Base URL 与当前第三方地址不匹配")
    if provider.get("env_key") != env_name:
        raise SystemExit("稳定会话供应商 env_key 与当前第三方密钥变量不匹配")
    if provider.get("requires_openai_auth"):
        raise SystemExit("第三方模式不应启用 OpenAI 登录认证")
else:
    if backup_path.is_file():
        with backup_path.open("rb") as handle:
            original = tomllib.load(handle)
    else:
        original = {}
    for key in ("model", "model_reasoning_effort"):
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
    if provider.get("base_url", "").rstrip("/") != official_base_url.rstrip("/"):
        raise SystemExit("官方模式稳定会话供应商 Base URL 不匹配")
    if provider.get("requires_openai_auth") is not True:
        raise SystemExit("官方模式稳定会话供应商未启用 OpenAI 登录认证")
    for forbidden in ("env_key", "experimental_bearer_token", "auth"):
        if forbidden in provider:
            raise SystemExit(f"官方模式稳定会话供应商不应包含 {forbidden}")
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
