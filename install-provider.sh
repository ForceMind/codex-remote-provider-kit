#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

usage() {
  cat <<'EOF'
用法：sudo -E ./install-provider.sh --base-url URL --model MODEL [选项]

选项：
  --provider-id ID       供应商/配置档 ID（默认：third_party）
  --env-name NAME        API 密钥环境变量名（默认：THIRD_PARTY_API_KEY）
  --codex-home DIR       Codex 目录（默认：$CODEX_HOME 或 /root/.codex）
  --codex-bin PATH       Codex 可执行文件（自动检测）
  --reasoning EFFORT     推理强度（默认：high）
  --allow-http           明确允许使用不加密的 HTTP（仅建议本机测试）
EOF
}

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

provider_id='third_party'
env_name='THIRD_PARTY_API_KEY'
base_url=''
model=''
reasoning='high'
codex_home="${CODEX_HOME:-/root/.codex}"
codex_bin=''
allow_http='no'

while (($#)); do
  case "$1" in
    --provider-id) provider_id=${2:?}; shift 2 ;;
    --env-name) env_name=${2:?}; shift 2 ;;
    --base-url) base_url=${2:?}; shift 2 ;;
    --model) model=${2:?}; shift 2 ;;
    --reasoning) reasoning=${2:?}; shift 2 ;;
    --codex-home) codex_home=${2:?}; shift 2 ;;
    --codex-bin) codex_bin=${2:?}; shift 2 ;;
    --allow-http) allow_http='yes'; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

((EUID == 0)) || die '请以 root 身份运行'
[[ -n "$base_url" && -n "$model" ]] || { usage; die '必须提供 --base-url 和 --model'; }
[[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || die '供应商 ID 无效'
[[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die '环境变量名无效'
[[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || die '模型名称无效'
[[ "$reasoning" =~ ^(none|minimal|low|medium|high|xhigh)$ ]] || die '推理强度无效'
[[ "$base_url" =~ ^https?://[^[:space:]]+$ ]] || die 'Base URL 必须是无空格的 HTTP(S) 地址'
[[ "$base_url" != *\"* && "$base_url" != *\\* ]] || die 'Base URL 不能包含引号或反斜杠'
[[ "$base_url" != *'@'* ]] || die 'Base URL 不能包含用户名、密码或 @ 字符'
[[ "$base_url" != *'?'* && "$base_url" != *'#'* ]] || die 'Base URL 不能包含查询参数或片段'
base_url=${base_url%/}
placeholder_url_pattern='^https?://([^/]+\.)?example\.(com|org|net)(/|$)|^https?://[^/]+\.(example|invalid)(/|$)'
[[ ! "$base_url" =~ $placeholder_url_pattern ]] || die '示例 Base URL 不能用于安装；请填写真实的第三方接口地址'
if [[ "$base_url" == http://* && "$allow_http" != yes ]]; then
  die '第三方 API 默认必须使用 HTTPS；仅本机测试时可明确传入 --allow-http'
fi

if [[ -z "$codex_bin" ]]; then
  command_codex=$(command -v codex 2>/dev/null || true)
  for candidate in "$command_codex" /root/.local/bin/codex /usr/local/bin/codex /usr/bin/codex; do
    [[ -n "$candidate" ]] || continue
    [[ -x "$candidate" ]] && { codex_bin=$candidate; break; }
  done
fi
[[ -n "$codex_bin" && -x "$codex_bin" ]] || die '未找到 Codex 可执行文件；请通过 --codex-bin 指定'
"$codex_bin" remote-control start --help >/dev/null 2>&1 || die '当前 Codex 版本不支持 remote-control start'
is_chatgpt_logged_in "$codex_bin" || die 'Codex 尚未通过 ChatGPT 登录'

api_key=${!env_name-}
if [[ -z "$api_key" && -t 0 ]]; then
  read -rsp "请输入第三方 API 密钥（${env_name}）：" api_key
  printf '\n'
  if [[ -n "$api_key" ]]; then
    printf '已收到 API 密钥（%d 个字符，内容已隐藏）。\n' "${#api_key}"
  fi
fi
[[ -n "$api_key" ]] || die "请设置 $env_name，或在交互式终端中运行"
is_supported_api_key "$api_key" || die 'API 密钥包含不支持的字符；请只复制密钥本身，不要包含空格或引号'

timestamp=$(date +%Y%m%d-%H%M%S)
config_file="$codex_home/config.toml"
profile_file="$codex_home/$provider_id.config.toml"
backup_dir="$codex_home/provider-kit-backups/$timestamp"
[[ ! -e "$backup_dir" ]] || backup_dir="$backup_dir-$$"
secret_file=${CODEX_RP_SECRET_FILE:-/etc/codex-remote-provider/provider.env}
secret_dir=$(dirname "$secret_file")
state_file=${CODEX_RP_STATE_FILE:-/var/lib/codex-remote-provider/state.env}
state_dir=$(dirname "$state_file")
third_party_unit_file=${CODEX_RP_THIRD_PARTY_UNIT_FILE:-/etc/systemd/system/codex-remote-provider.service}
official_unit_file=${CODEX_RP_OFFICIAL_UNIT_FILE:-/etc/systemd/system/codex-remote-official.service}
third_party_unit_name=${third_party_unit_file##*/}
official_unit_name=${official_unit_file##*/}
command_file=${CODEX_RP_COMMAND_FILE:-/usr/local/bin/codex-rp}
command_marker='# Managed by codex-remote-provider-kit'
begin_marker="# BEGIN codex-remote-provider-kit:$provider_id"
end_marker="# END codex-remote-provider-kit:$provider_id"

[[ ! -e "$state_file" ]] || die '检测到现有安装状态；请通过 setup.sh 管理，或先完整回滚'
[[ ! -e "$secret_file" ]] || die "检测到没有状态记录的旧密钥文件：$secret_file；请先人工确认并移走"
if [[ -e "$command_file" ]] && ! grep -Fxq "$command_marker" "$command_file"; then
  die "$command_file 已存在，且不由本套件管理"
fi

install -d -m 700 "$codex_home" "$backup_dir" "$secret_dir" "$state_dir"
config_existed='no'
profile_existed='no'
if [[ -f "$config_file" ]]; then
  config_existed='yes'
  cp -p "$config_file" "$backup_dir/config.toml"
fi
if [[ -f "$profile_file" ]]; then
  profile_existed='yes'
  cp -p "$profile_file" "$backup_dir/profile.config.toml"
fi

third_party_unit_existed='no'
official_unit_existed='no'
command_existed='no'
if [[ -f "$third_party_unit_file" ]]; then
  third_party_unit_existed='yes'
  cp -p "$third_party_unit_file" "$backup_dir/codex-remote-provider.service"
fi
if [[ -f "$official_unit_file" ]]; then
  official_unit_existed='yes'
  cp -p "$official_unit_file" "$backup_dir/codex-remote-official.service"
fi
if [[ -f "$command_file" ]]; then
  command_existed='yes'
  cp -p "$command_file" "$backup_dir/codex-rp"
fi

legacy_enabled='no'
legacy_active='no'
third_party_unit_enabled='no'
third_party_unit_active='no'
official_unit_enabled='no'
official_unit_active='no'
systemctl is-enabled codex.service >/dev/null 2>&1 && legacy_enabled='yes'
systemctl is-active codex.service >/dev/null 2>&1 && legacy_active='yes'
systemctl is-enabled "$third_party_unit_name" >/dev/null 2>&1 && third_party_unit_enabled='yes'
systemctl is-active "$third_party_unit_name" >/dev/null 2>&1 && third_party_unit_active='yes'
systemctl is-enabled "$official_unit_name" >/dev/null 2>&1 && official_unit_enabled='yes'
systemctl is-active "$official_unit_name" >/dev/null 2>&1 && official_unit_active='yes'

tmp_config=$(mktemp)
tmp_profile=$(mktemp)
tmp_secret=$(mktemp)
tmp_third_party_unit=$(mktemp)
tmp_official_unit=$(mktemp)
tmp_command=$(mktemp)
tmp_state=$(mktemp)
cleanup() {
  rm -f "$tmp_config" "$tmp_profile" "$tmp_secret" \
    "$tmp_third_party_unit" "$tmp_official_unit" "$tmp_command" "$tmp_state"
}
trap cleanup EXIT

if [[ -f "$config_file" ]]; then
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$config_file" > "$tmp_config"
fi

if grep -Eq "^[[:space:]]*\[model_providers\.${provider_id//./\\.}\][[:space:]]*$" "$tmp_config"; then
  die "配置已在本套件管理区块之外定义 model_providers.$provider_id"
fi

# The managed Remote daemon is a separate process. It reads the user-level
# default provider and does not reliably inherit transient bootstrap flags.
set_remote_defaults "$tmp_config" "$provider_id" "$model" "$reasoning"

cat >> "$tmp_config" <<EOF

$begin_marker
[model_providers.$provider_id]
name = "$provider_id"
base_url = "$base_url"
env_key = "$env_name"
wire_api = "responses"
$end_marker
EOF

cat > "$tmp_profile" <<EOF
model = "$model"
model_provider = "$provider_id"
model_reasoning_effort = "$reasoning"
EOF

write_secret_environment_file "$tmp_secret" "$env_name" "$api_key"

write_third_party_unit "$tmp_third_party_unit" "$codex_bin" "$secret_file" \
  "$provider_id" "$model" "$reasoning"
write_official_unit "$tmp_official_unit" "$codex_bin"

write_command_launcher "$tmp_command" "$script_dir/setup.sh"

python3 - "$tmp_config" "$tmp_profile" <<'PY'
import sys, tomllib
for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        tomllib.load(handle)
print("TOML 验证：通过")
PY

{
  printf 'PROVIDER_ID=%q\n' "$provider_id"
  printf 'ENV_NAME=%q\n' "$env_name"
  printf 'BASE_URL=%q\n' "$base_url"
  printf 'MODEL=%q\n' "$model"
  printf 'REASONING=%q\n' "$reasoning"
  printf 'CODEX_HOME_DIR=%q\n' "$codex_home"
  printf 'CODEX_BIN_PATH=%q\n' "$codex_bin"
  printf 'COMMAND_FILE=%q\n' "$command_file"
  printf 'BACKUP_DIR=%q\n' "$backup_dir"
  printf 'THIRD_PARTY_UNIT_FILE=%q\n' "$third_party_unit_file"
  printf 'OFFICIAL_UNIT_FILE=%q\n' "$official_unit_file"
  printf 'THIRD_PARTY_UNIT_EXISTED=%q\n' "$third_party_unit_existed"
  printf 'THIRD_PARTY_UNIT_ENABLED=%q\n' "$third_party_unit_enabled"
  printf 'THIRD_PARTY_UNIT_ACTIVE=%q\n' "$third_party_unit_active"
  printf 'OFFICIAL_UNIT_EXISTED=%q\n' "$official_unit_existed"
  printf 'OFFICIAL_UNIT_ENABLED=%q\n' "$official_unit_enabled"
  printf 'OFFICIAL_UNIT_ACTIVE=%q\n' "$official_unit_active"
  printf 'COMMAND_EXISTED=%q\n' "$command_existed"
  printf 'LEGACY_ENABLED=%q\n' "$legacy_enabled"
  printf 'LEGACY_ACTIVE=%q\n' "$legacy_active"
} > "$tmp_state"
chmod 600 "$tmp_state"

handle_install_error() {
  local exit_status=$?

  trap - ERR
  set +e
  printf '安装未完成，正在恢复安装前状态……\n' >&2
  systemctl disable --now "$third_party_unit_name" >/dev/null 2>&1
  systemctl disable --now "$official_unit_name" >/dev/null 2>&1
  "$codex_bin" remote-control stop --json >/dev/null 2>&1

  if [[ "$config_existed" == yes ]]; then
    install -m 600 "$backup_dir/config.toml" "$config_file"
  else
    rm -f "$config_file"
  fi
  if [[ "$profile_existed" == yes ]]; then
    install -m 600 "$backup_dir/profile.config.toml" "$profile_file"
  else
    rm -f "$profile_file"
  fi
  rm -f "$secret_file" "$state_file"

  if [[ "$third_party_unit_existed" == yes ]]; then
    install -m 644 "$backup_dir/codex-remote-provider.service" "$third_party_unit_file"
  else
    rm -f "$third_party_unit_file"
  fi
  if [[ "$official_unit_existed" == yes ]]; then
    install -m 644 "$backup_dir/codex-remote-official.service" "$official_unit_file"
  else
    rm -f "$official_unit_file"
  fi
  if [[ "$command_existed" == yes ]]; then
    install -m 755 "$backup_dir/codex-rp" "$command_file"
  elif [[ -f "$command_file" ]] && grep -Fxq "$command_marker" "$command_file"; then
    rm -f "$command_file"
  fi

  systemctl daemon-reload >/dev/null 2>&1
  if [[ "$third_party_unit_existed" == yes ]]; then
    if [[ "$third_party_unit_enabled" == yes ]]; then
      systemctl enable "$third_party_unit_name" >/dev/null 2>&1
    else
      systemctl disable "$third_party_unit_name" >/dev/null 2>&1
    fi
    if [[ "$third_party_unit_active" == yes ]]; then
      systemctl start "$third_party_unit_name" >/dev/null 2>&1
    fi
  fi
  if [[ "$official_unit_existed" == yes ]]; then
    if [[ "$official_unit_enabled" == yes ]]; then
      systemctl enable "$official_unit_name" >/dev/null 2>&1
    else
      systemctl disable "$official_unit_name" >/dev/null 2>&1
    fi
    if [[ "$official_unit_active" == yes ]]; then
      systemctl start "$official_unit_name" >/dev/null 2>&1
    fi
  fi
  if [[ "$legacy_enabled" == yes ]]; then
    systemctl enable codex.service >/dev/null 2>&1
  fi
  if [[ "$legacy_active" == yes ]]; then
    systemctl start codex.service >/dev/null 2>&1
  fi
  printf '已尝试恢复原配置和服务；故障前备份保留在：%s\n' "$backup_dir" >&2
  exit "$exit_status"
}
trap handle_install_error ERR

install -m 600 "$tmp_config" "$config_file"
install -m 600 "$tmp_profile" "$profile_file"
install -m 600 "$tmp_secret" "$secret_file"
install -m 644 "$tmp_third_party_unit" "$third_party_unit_file"
install -m 644 "$tmp_official_unit" "$official_unit_file"
install -m 755 "$tmp_command" "$command_file"

if [[ "$legacy_active" == yes ]]; then systemctl stop codex.service; fi
if [[ "$legacy_enabled" == yes ]]; then systemctl --quiet disable codex.service; fi
"$codex_bin" remote-control stop --json >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl --quiet disable --now "$official_unit_name" >/dev/null 2>&1 || true
systemctl --quiet enable --now "$third_party_unit_name"
require_active_systemd_unit "$third_party_unit_name"
install -m 600 "$tmp_state" "$state_file"
trap - ERR

printf '已安装供应商 %s，模型为 %s。\n' "$provider_id" "$model"
printf '备份位置：%s\n' "$backup_dir"
printf '后台服务已启动，并已设为开机自启。\n'
printf '可在任意目录打开管理面板：codex-rp\n'
printf '完整验证命令：sudo %s/status.sh --full\n' "$script_dir"
