#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ $(uname -s) == Darwin ]]; then
  exec "$script_dir/platform/macos/codex-rp.sh" "$@"
fi
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

usage() {
  cat <<'EOF'
Codex Remote 第三方模型供应商管理工具

用法：
  ./panel.sh
  codex-rp
  sudo ./setup.sh [命令] [安装选项]

命令：
  menu          打开交互式管理面板
  install       安装 Codex（如缺少）、启动 Remote 并完整验证（默认）
  codex         仅安装/检查 Codex CLI 并完成 ChatGPT 登录
  status        查看服务和配置状态，不生成模型回复
  test          检查接口并执行一次最小化的真实 Codex 回合
  official      手动将 Remote 切换到默认/官方供应商
  third-party   启动或切换到已安装的第三方供应商
  rollback      恢复安装前配置并移除已保存的密钥
  help          显示本帮助

默认安装设置：
  接口地址：      https://api.example.com/v1（示例，安装时必须替换）
  模型：          gpt-5.6-sol
  供应商 ID：     third_party
  Codex 目录：    /root/.codex

示例：
  ./panel.sh
  codex-rp
  sudo ./setup.sh install
  sudo ./setup.sh test
  sudo ./setup.sh official
  sudo ./setup.sh install --base-url https://provider.example/v1 --model gpt-5.5

安装选项会传递给 install-provider.sh。第三方地址默认必须使用 HTTPS；只有本机
隔离测试确实需要明文 HTTP 时，才可显式增加 --allow-http。

安装器会以不回显的方式询问供应商密钥。切勿通过命令行参数传递密钥，
也不要将密钥保存在本仓库中。
EOF
}

command_name=${1:-menu}
if (($#)); then shift; fi

case "$command_name" in
  help|-h|--help) usage; exit 0 ;;
  menu|install|codex|status|test|official|third-party|start|rollback) ;;
  *)
    printf '错误：未知命令：%s\n\n' "$command_name" >&2
    usage >&2
    exit 2
    ;;
esac

show_panel() {
  local choice
  while true; do
    printf '\n'
    printf 'Codex Remote 第三方模型供应商套件\n'
    printf '=================================\n'
    printf '1) 从零安装 / 重启第三方 Remote\n'
    printf '2) 查看基础状态\n'
    printf '3) 运行完整连接测试\n'
    printf '4) 切换到第三方推理\n'
    printf '5) 切换到官方推理\n'
    printf '6) 完整回滚\n'
    printf '7) 查看帮助\n'
    printf '8) 仅安装 / 检查 Codex CLI\n'
    printf '0) 退出\n'
    printf '请选择 [0-8]: '
    if ! read -r choice; then
      printf '\n输入已关闭，退出。\n'
      return 0
    fi
    case "$choice" in
      1) panel_install ;;
      2) "$script_dir/setup.sh" status ;;
      3) "$script_dir/setup.sh" test ;;
      4) "$script_dir/setup.sh" third-party ;;
      5) "$script_dir/setup.sh" official ;;
      6) "$script_dir/setup.sh" rollback ;;
      7) usage ;;
      8) "$script_dir/setup.sh" codex ;;
      0) return 0 ;;
      *) printf '无效选项，请输入 0 到 8。\n' >&2 ;;
    esac
  done
}

panel_install() {
  local base_url model provider_id reasoning input

  if [[ -r /var/lib/codex-remote-provider/state.env ]]; then
    "$script_dir/setup.sh" install
    return
  fi

  "$script_dir/setup.sh" codex || return 1

  base_url='https://api.example.com/v1'
  model='gpt-5.6-sol'
  provider_id='third_party'
  reasoning='high'

  while true; do
    printf '接口地址（Base URL）[%s]: ' "$base_url"
    read -r input || return 1
    base_url=${input:-$base_url}
    if [[ "$base_url" != 'https://api.example.com/v1' ]]; then
      break
    fi
    printf '该地址只是示例，请输入真实的第三方接口地址。\n' >&2
  done
  printf '模型 [%s]: ' "$model"
  read -r input || return 1
  model=${input:-$model}
  printf '供应商 ID（Provider ID）[%s]: ' "$provider_id"
  read -r input || return 1
  provider_id=${input:-$provider_id}
  printf '推理强度 none/minimal/low/medium/high/xhigh [%s]: ' "$reasoning"
  read -r input || return 1
  reasoning=${input:-$reasoning}

  "$script_dir/setup.sh" install \
    --base-url "$base_url" \
    --model "$model" \
    --provider-id "$provider_id" \
    --reasoning "$reasoning"
}

if ((EUID != 0)); then
  command -v sudo >/dev/null 2>&1 || {
    printf '错误：需要 root 权限，但系统中没有可用的 sudo\n' >&2
    exit 1
  }
  exec sudo "$script_dir/setup.sh" "$command_name" "$@"
fi

case "$command_name" in
  menu)
    (($# == 0)) || { printf '错误：menu 命令不接受选项\n' >&2; exit 2; }
    install_global_command "$script_dir/setup.sh"
    show_panel
    ;;
  install)
    if [[ -r /var/lib/codex-remote-provider/state.env ]]; then
      if (($#)); then
        printf '错误：供应商套件已安装，额外安装选项未生效\n' >&2
        printf '如需使用不同设置重新安装，请先运行 sudo ./rollback.sh\n' >&2
        exit 1
      fi
      install_global_command "$script_dir/setup.sh"
      printf '检测到现有安装；正在重启第三方 Remote 服务。\n'
      "$script_dir/use-third-party.sh"
    else
      has_base_url='no'
      install_options=("$@")
      for ((option_index=0; option_index<${#install_options[@]}; option_index++)); do
        if [[ "${install_options[option_index]}" == '--base-url' ]]; then
          has_base_url='yes'
          break
        fi
      done
      if [[ "$has_base_url" == no ]]; then
        [[ -t 0 ]] || {
          printf '错误：非交互安装必须通过 --base-url 提供真实的第三方接口地址\n' >&2
          exit 2
        }
        while true; do
          printf '请输入真实的第三方接口地址（示例：https://api.example.com/v1）：'
          read -r required_base_url
          if [[ -n "$required_base_url" && "$required_base_url" != 'https://api.example.com/v1' ]]; then
            set -- "$@" --base-url "$required_base_url"
            break
          fi
          printf '该地址不能为空，也不能使用示例地址。\n' >&2
        done
      fi
      install_options=("$@")
      codex_setup_options=()
      for ((option_index=0; option_index<${#install_options[@]}; option_index++)); do
        if [[ "${install_options[option_index]}" == '--codex-bin' ]] \
            && ((option_index + 1 < ${#install_options[@]})); then
          codex_setup_options=(--codex-bin "${install_options[option_index + 1]}")
          break
        fi
      done
      "$script_dir/install-codex.sh" "${codex_setup_options[@]}"
      "$script_dir/install-provider.sh" \
        --base-url https://api.example.com/v1 \
        --model gpt-5.6-sol \
        --provider-id third_party \
        --codex-home /root/.codex \
        "$@"
    fi
    printf '\n正在运行完整验证……\n'
    "$script_dir/status.sh" --full
    printf '\n准备就绪。请在手机端新建对话并发送：Reply exactly OK\n'
    ;;
  codex)
    "$script_dir/install-codex.sh" "$@"
    ;;
  status)
    (($# == 0)) || { printf '错误：status 命令不接受选项\n' >&2; exit 2; }
    "$script_dir/status.sh"
    ;;
  test)
    (($# == 0)) || { printf '错误：test 命令不接受选项\n' >&2; exit 2; }
    "$script_dir/status.sh" --full
    ;;
  official)
    (($# == 0)) || { printf '错误：official 命令不接受选项\n' >&2; exit 2; }
    "$script_dir/use-official.sh"
    ;;
  third-party|start)
    (($# == 0)) || { printf '错误：third-party 命令不接受选项\n' >&2; exit 2; }
    "$script_dir/use-third-party.sh"
    "$script_dir/status.sh"
    ;;
  rollback)
    (($# == 0)) || { printf '错误：rollback 命令不接受选项\n' >&2; exit 2; }
    "$script_dir/rollback.sh"
    ;;
esac
