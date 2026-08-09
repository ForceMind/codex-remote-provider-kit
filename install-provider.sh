#!/usr/bin/env bash
set -euo pipefail

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

while (($#)); do
  case "$1" in
    --provider-id) provider_id=${2:?}; shift 2 ;;
    --env-name) env_name=${2:?}; shift 2 ;;
    --base-url) base_url=${2:?}; shift 2 ;;
    --model) model=${2:?}; shift 2 ;;
    --reasoning) reasoning=${2:?}; shift 2 ;;
    --codex-home) codex_home=${2:?}; shift 2 ;;
    --codex-bin) codex_bin=${2:?}; shift 2 ;;
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
base_url=${base_url%/}
placeholder_url_pattern='^https?://([^/]+\.)?example\.(com|org|net)(/|$)|^https?://[^/]+\.(example|invalid)(/|$)'
[[ ! "$base_url" =~ $placeholder_url_pattern ]] || die '示例 Base URL 不能用于安装；请填写真实的第三方接口地址'

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
secret_dir='/etc/codex-remote-provider'
secret_file="$secret_dir/provider.env"
state_dir='/var/lib/codex-remote-provider'
state_file="$state_dir/state.env"
unit_file='/etc/systemd/system/codex-remote-provider.service'
command_file='/usr/local/bin/codex-rp'
command_marker='# Managed by codex-remote-provider-kit'
begin_marker="# BEGIN codex-remote-provider-kit:$provider_id"
end_marker="# END codex-remote-provider-kit:$provider_id"

if [[ -e "$command_file" ]] && ! grep -Fxq "$command_marker" "$command_file"; then
  die "$command_file 已存在，且不由本套件管理"
fi

install -d -m 700 "$codex_home" "$backup_dir" "$secret_dir" "$state_dir"
[[ -f "$config_file" ]] && cp -p "$config_file" "$backup_dir/config.toml"
[[ -f "$profile_file" ]] && cp -p "$profile_file" "$backup_dir/profile.config.toml"
[[ -f "$unit_file" ]] && cp -p "$unit_file" "$backup_dir/codex-remote-provider.service"

legacy_enabled='no'
legacy_active='no'
systemctl is-enabled codex.service >/dev/null 2>&1 && legacy_enabled='yes'
systemctl is-active codex.service >/dev/null 2>&1 && legacy_active='yes'

tmp_config=$(mktemp)
tmp_profile=$(mktemp)
tmp_secret=$(mktemp)
tmp_unit=$(mktemp)
tmp_command=$(mktemp)
cleanup() { rm -f "$tmp_config" "$tmp_profile" "$tmp_secret" "$tmp_unit" "$tmp_command"; }
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

printf '%s=%s\n' "$env_name" "$api_key" > "$tmp_secret"

cat > "$tmp_unit" <<EOF
[Unit]
Description=使用自定义模型供应商的 Codex Remote
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
WorkingDirectory=/root
Environment=HOME=/root
EnvironmentFile=$secret_file
ExecStart=$codex_bin remote-control start --json -c model_provider=$provider_id -c model=$model -c model_reasoning_effort=$reasoning
ExecStop=$codex_bin remote-control stop --json
Restart=no

[Install]
WantedBy=multi-user.target
EOF

write_command_launcher "$tmp_command" "$script_dir/setup.sh"

python3 - "$tmp_config" "$tmp_profile" <<'PY'
import sys, tomllib
for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        tomllib.load(handle)
print("TOML 验证：通过")
PY

install -m 600 "$tmp_config" "$config_file"
install -m 600 "$tmp_profile" "$profile_file"
install -m 600 "$tmp_secret" "$secret_file"
install -m 644 "$tmp_unit" "$unit_file"
install -m 755 "$tmp_command" "$command_file"

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
  printf 'LEGACY_ENABLED=%q\n' "$legacy_enabled"
  printf 'LEGACY_ACTIVE=%q\n' "$legacy_active"
} > "$state_file"
chmod 600 "$state_file"

if [[ "$legacy_active" == yes ]]; then systemctl stop codex.service; fi
if [[ "$legacy_enabled" == yes ]]; then systemctl --quiet disable codex.service; fi
"$codex_bin" remote-control stop --json >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl --quiet enable --now codex-remote-provider.service

printf '已安装供应商 %s，模型为 %s。\n' "$provider_id" "$model"
printf '备份位置：%s\n' "$backup_dir"
printf '后台服务已启动，并已设为开机自启。\n'
printf '可在任意目录打开管理面板：codex-rp\n'
printf '完整验证命令：sudo %s/status.sh --full\n' "$script_dir"
