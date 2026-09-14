#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

usage() {
  cat <<'EOF'
用法：sudo ./install-codex.sh [--codex-bin PATH]

检查新机器所需依赖；缺少 Codex CLI 时，通过 OpenAI 官方独立安装器
安装，并引导完成 ChatGPT 设备登录。

选项：
  --codex-bin PATH   使用已有的 Codex 可执行文件，不执行在线安装
  -h, --help         显示本帮助
EOF
}

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

download_connect_timeout=${CODEX_RP_DOWNLOAD_CONNECT_TIMEOUT:-10}
download_max_time=${CODEX_RP_DOWNLOAD_MAX_TIME:-60}
download_retries=${CODEX_RP_DOWNLOAD_RETRIES:-2}
download_retry_delay=${CODEX_RP_DOWNLOAD_RETRY_DELAY:-1}
for limit in "$download_connect_timeout" "$download_max_time" "$download_retries" "$download_retry_delay"; do
  [[ "$limit" =~ ^[0-9]+$ ]] || die '下载超时和重试参数必须是非负整数'
done
((download_connect_timeout > 0 && download_max_time > 0)) || die '下载连接和总超时必须大于零'

download_to_stdout() {
  curl --fail --silent --show-error --location \
    --connect-timeout "$download_connect_timeout" --max-time "$download_max_time" \
    --retry "$download_retries" --retry-delay "$download_retry_delay" --retry-connrefused "$1"
}

codex_bin_override=''
while (($#)); do
  case "$1" in
    --codex-bin) codex_bin_override=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

((EUID == 0)) || die '请使用 sudo 或以 root 身份运行'
command -v systemctl >/dev/null 2>&1 || die '本套件需要使用 systemd 的 Linux 系统'

install_system_dependencies() {
  local -a missing=() packages=() required_commands=()
  local command_name

  required_commands=(curl python3)
  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  ((${#missing[@]})) || return 0

  printf '缺少系统依赖：%s\n' "${missing[*]}"
  printf '正在使用系统软件包管理器安装依赖……\n'

  if command -v apt-get >/dev/null 2>&1; then
    packages=(ca-certificates)
    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v python3 >/dev/null 2>&1 || packages+=(python3)
    apt-get update
    apt-get install -y "${packages[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    packages=(ca-certificates)
    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v python3 >/dev/null 2>&1 || packages+=(python3)
    dnf install -y "${packages[@]}"
  elif command -v yum >/dev/null 2>&1; then
    packages=(ca-certificates)
    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v python3 >/dev/null 2>&1 || packages+=(python3)
    yum install -y "${packages[@]}"
  else
    die '无法自动安装依赖；目前支持 apt-get、dnf 或 yum'
  fi

  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || die "安装后仍未找到 $command_name"
  done
}

find_compatible_codex() {
  local candidate
  local -a candidates=()

  if [[ -n "$codex_bin_override" ]]; then
    candidates+=("$codex_bin_override")
  else
    candidate=$(command -v codex 2>/dev/null || true)
    [[ -n "$candidate" ]] && candidates+=("$candidate")
    candidates+=(/root/.local/bin/codex /usr/local/bin/codex /usr/bin/codex)
  fi

  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate" ]] || continue
    if "$candidate" remote-control start --help >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

codex_bin=''
if codex_bin=$(find_compatible_codex); then
  printf '检测到兼容的 Codex CLI：%s\n' "$codex_bin"
elif [[ -n "$codex_bin_override" ]]; then
  die "指定的 Codex 不存在、不可执行或不支持 remote-control start：$codex_bin_override"
else
  install_system_dependencies
  printf '未检测到兼容的 Codex CLI，正在运行 OpenAI 官方独立安装器……\n'
  download_to_stdout https://chatgpt.com/codex/install.sh | sh
  hash -r
  for candidate in /root/.local/bin/codex /usr/local/bin/codex /usr/bin/codex; do
    if [[ -x "$candidate" ]] && "$candidate" remote-control start --help >/dev/null 2>&1; then
      codex_bin=$candidate
      break
    fi
  done
  [[ -n "$codex_bin" ]] || die 'Codex 安装完成，但未找到支持 Remote 的可执行文件'
  printf 'Codex CLI 安装完成：%s\n' "$codex_bin"
fi

# status.sh also needs these commands when Codex was already installed.
install_system_dependencies

if is_chatgpt_logged_in "$codex_bin"; then
  printf 'ChatGPT 登录状态：已登录\n'
else
  [[ -t 0 && -t 1 ]] || die 'Codex 尚未登录；请在交互式终端中重新运行本脚本'
  printf '\n接下来需要登录 ChatGPT；这与第三方供应商 API 密钥是两个独立凭据。\n'
  printf '请按照 Codex 显示的网址和设备代码完成登录。\n\n'
  login_help=$("$codex_bin" login --help 2>&1 || true)
  if [[ "$login_help" == *'--device-auth'* ]]; then
    "$codex_bin" login --device-auth
  else
    "$codex_bin" login
  fi
  is_chatgpt_logged_in "$codex_bin" || die 'ChatGPT 登录未完成'
  printf 'ChatGPT 登录完成。\n'
fi

printf 'Codex 已就绪：'
"$codex_bin" --version
