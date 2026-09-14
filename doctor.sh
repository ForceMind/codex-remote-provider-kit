#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

level='local'
json='no'
while (($#)); do
  case "$1" in
    --network) [[ "$level" == local ]] || { printf '错误：--network 与 --full 不能同时使用\n' >&2; exit 2; }; level='network' ;;
    --full) [[ "$level" == local ]] || { printf '错误：--network 与 --full 不能同时使用\n' >&2; exit 2; }; level='full' ;;
    --json) json='yes' ;;
    -h|--help)
      printf '用法：doctor.sh [--network|--full] [--json]\n'
      exit 0
      ;;
    *) printf '错误：未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [[ "$level" != local ]]; then
  [[ "$json" == no ]] || {
    printf '错误：网络诊断暂不支持 --json；请使用本地 doctor --json 或文本网络诊断\n' >&2
    exit 2
  }
  if [[ "$level" == full ]]; then
    exec "$script_dir/status.sh" --full
  fi
  exec "$script_dir/status.sh"
fi

state_file=${CODEX_RP_STATE_FILE:-/var/lib/codex-remote-provider/state.env}
secret_file=${CODEX_RP_SECRET_FILE:-/etc/codex-remote-provider/provider.env}
checks_file=$(mktemp)
cleanup() { rm -f "$checks_file"; }
trap cleanup EXIT
failures=0

add_check() {
  local id=${1:?check id required} status=${2:?status required} message=${3:?message required}
  printf '%s\t%s\t%s\n' "$id" "$status" "$message" >> "$checks_file"
  [[ "$status" != FAIL && "$status" != BLOCKED ]] || failures=$((failures + 1))
}

if [[ ! -r "$state_file" ]]; then
  add_check install.state FAIL '未找到活动安装状态'
else
  add_check install.state PASS '活动安装状态存在'
  if read_codex_rp_state "$state_file"; then
    add_check state.syntax PASS '状态文件通过安全解析'
  else
    add_check state.syntax FAIL '状态文件格式或字段不受支持'
  fi
fi

if ((failures == 0)); then
  third_party_unit_file=${THIRD_PARTY_UNIT_FILE:-/etc/systemd/system/codex-remote-provider.service}
  official_unit_file=${OFFICIAL_UNIT_FILE:-/etc/systemd/system/codex-remote-official.service}
  third_party_name=${third_party_unit_file##*/}
  official_name=${official_unit_file##*/}
  third_active='no'; official_active='no'
  systemctl is-active "$third_party_name" >/dev/null 2>&1 && third_active='yes'
  systemctl is-active "$official_name" >/dev/null 2>&1 && official_active='yes'
  if [[ "$third_active" == yes && "$official_active" == no ]]; then
    mode='third-party'; add_check remote.service_selection PASS '仅第三方 Remote unit 处于 active'
  elif [[ "$official_active" == yes && "$third_active" == no ]]; then
    mode='official'; add_check remote.service_selection PASS '仅官方 Remote unit 处于 active'
  else
    mode='inconsistent'; add_check remote.service_selection FAIL 'Remote unit 未保持互斥运行'
  fi

  if [[ -f "$third_party_unit_file" ]] && grep -Fxq '# Managed by codex-remote-provider-kit' "$third_party_unit_file" \
      && [[ -f "$official_unit_file" ]] && grep -Fxq '# Managed by codex-remote-provider-kit' "$official_unit_file"; then
    add_check unit.ownership PASS '两个 Remote unit 均由本工具管理'
  else
    add_check unit.ownership BLOCKED 'Remote unit 缺失或所有权不明确'
  fi

  config_file="$CODEX_HOME_DIR/config.toml"
  profile_file="$CODEX_HOME_DIR/$PROVIDER_ID.config.toml"
  if python3 - "$config_file" "$profile_file" "$PROVIDER_ID" "$MODEL" "$REASONING" "$mode" "$BACKUP_DIR/config.toml" <<'PY' >/dev/null 2>&1
import pathlib, sys, tomllib
config_path, profile_path = map(pathlib.Path, sys.argv[1:3])
provider, model, reasoning, mode = sys.argv[3:7]
backup_path = pathlib.Path(sys.argv[7])
with config_path.open('rb') as handle:
    config = tomllib.load(handle)
if mode == 'third-party':
    with profile_path.open('rb') as handle:
        tomllib.load(handle)
    assert config.get('model_provider') == provider
    assert config.get('model') == model
    assert config.get('model_reasoning_effort') == reasoning
elif mode == 'official':
    original = tomllib.loads(backup_path.read_text()) if backup_path.is_file() else {}
    for key in ('model_provider', 'model', 'model_reasoning_effort'):
        assert config.get(key) == original.get(key)
else:
    raise AssertionError('inconsistent mode')
PY
  then
    add_check config.defaults PASS '用户级三项默认配置与当前模式一致'
  else
    add_check config.defaults FAIL '用户级三项默认配置不一致或 TOML 无效'
  fi

  begin_marker="# BEGIN codex-remote-provider-kit:$PROVIDER_ID"
  end_marker="# END codex-remote-provider-kit:$PROVIDER_ID"
  if [[ -f "$config_file" && $(grep -Fxc "$begin_marker" "$config_file" || true) == 1 \
      && $(grep -Fxc "$end_marker" "$config_file" || true) == 1 ]]; then
    add_check config.ownership PASS '受管 provider 标记完整且唯一'
  else
    add_check config.ownership BLOCKED '受管 provider 标记缺失、残缺或重复'
  fi

  if [[ -r "$secret_file" ]] && read_secret_environment_value "$secret_file" "$ENV_NAME"; then
    CODEX_RP_SECRET_VALUE=''
    add_check credential.access PASS '第三方凭据存在且格式有效'
  else
    add_check credential.access FAIL '第三方凭据缺失、不可读或格式无效'
  fi

  if [[ -x "$CODEX_BIN_PATH" ]]; then
    add_check codex.binary PASS 'Codex CLI 可执行'
    if is_chatgpt_logged_in "$CODEX_BIN_PATH"; then
      add_check codex.chatgpt_login PASS 'Codex 已使用 ChatGPT 登录'
    else
      add_check codex.chatgpt_login WARN '未能确认 ChatGPT 登录'
    fi
  else
    add_check codex.binary FAIL 'Codex CLI 不可执行'
    add_check codex.chatgpt_login UNKNOWN '未检查登录状态'
  fi
  add_check remote.host_readiness UNKNOWN 'systemd active/exited 不能证明派生 Remote daemon 持续健康；请使用 doctor --full 并从手机新建会话验证'
fi

if [[ "$json" == yes ]]; then
  python3 - "$checks_file" "$failures" <<'PY'
import json, pathlib, sys
checks=[]
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    check_id, status, message = line.split('\t', 2)
    checks.append({'id': check_id, 'status': status, 'message': message})
print(json.dumps({'schema_version': 1, 'platform': 'linux', 'checks': checks,
                  'ok': int(sys.argv[2]) == 0}, ensure_ascii=False))
PY
else
  while IFS=$'\t' read -r id status message; do
    printf '[%s] %s：%s\n' "$status" "$id" "$message"
  done < "$checks_file"
fi
((failures == 0))
