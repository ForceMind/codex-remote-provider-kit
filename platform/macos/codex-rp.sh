#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_dir=$(cd -- "$script_dir/../.." && pwd -P)

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Codex 远程模型服务工具（macOS）

用法：
  codex-rp [命令] [安装选项]

命令：
  menu          打开中文管理面板（默认）
  install       安装/配置第三方 provider
  status        检查配置、Keychain、Codex 与 ChatGPT 桌面应用
  test          执行一次最小化的第三方 Codex 真实调用
  official      恢复安装前的官方默认模型配置
  third-party   重新启用第三方模型配置
  rotate-key    更新 macOS Keychain 中的第三方密钥
  shortcut      安装/刷新 Finder、Spotlight 和 Dock 可用的 .app 快捷入口
  restart-app   明确重启 ChatGPT 桌面应用以加载新配置
  rollback      恢复安装前配置并删除 Keychain 密钥

安装选项：
  --base-url URL       第三方 Responses API Base URL（必须是 HTTPS）
  --model MODEL        模型（默认：gpt-5.6-sol）
  --provider-id ID     Provider ID（默认：third_party）
  --reasoning EFFORT   none/minimal/low/medium/high/xhigh（默认：high）
  --codex-bin PATH     指定 Codex CLI

脚本只修改用户级 ~/.codex 配置、本用户的 macOS Keychain 和套件管理的
快捷启动入口，不修改 ChatGPT 登录、workspace、Remote 配对或会话历史。
切换后请重启桌面应用并新建会话。
EOF
}

platform_name=${CODEX_RP_TEST_PLATFORM:-$(uname -s)}
[[ "$platform_name" == Darwin ]] || die '此入口仅支持 macOS'

codex_home=${CODEX_HOME:-$HOME/.codex}
data_dir=${CODEX_RP_DATA_DIR:-$HOME/Library/Application Support/CodexRemoteProviderKit}
active_dir="$data_dir/active"
audit_dir="$data_dir/audit"
config_file="$codex_home/config.toml"
security_bin=${CODEX_RP_SECURITY_BIN:-/usr/bin/security}
launcher_file=${CODEX_RP_COMMAND_FILE:-$HOME/.local/bin/codex-rp}
launcher_marker='# Managed by codex-remote-provider-kit:macos'
legacy_app_launcher=''
if [[ -n ${CODEX_RP_APP_BUNDLE+x} ]]; then
  app_launcher=$CODEX_RP_APP_BUNDLE
else
  app_launcher="$HOME/Applications/Codex 远程模型服务工具.app"
  legacy_app_launcher="$HOME/Applications/Codex Remote Provider Kit.app"
fi
app_launcher_marker='Managed by codex-remote-provider-kit:macos-app'

make_temp() {
  mktemp "${TMPDIR:-/tmp}/codex-rp.XXXXXX"
}

make_target_temp() {
  local target=${1:?target file required}
  mktemp "$(dirname "$target")/.codex-rp.XXXXXX"
}

validate_provider_id() { [[ ${1-} =~ ^[A-Za-z0-9_-]+$ ]]; }
validate_model() { [[ ${1-} =~ ^[A-Za-z0-9._-]+$ ]]; }
validate_reasoning() { [[ ${1-} =~ ^(none|minimal|low|medium|high|xhigh)$ ]]; }
validate_api_key() { [[ -n ${1-} && ${1-} =~ ^[A-Za-z0-9._~+/=-]+$ ]]; }

validate_base_url() {
  local value=${1-} authority host
  [[ "$value" =~ ^https://[^[:space:]\"\\@?#]+(/[^[:space:]\"\\@?#]*)?$ ]] || return 1
  authority=${value#https://}
  authority=${authority%%/*}
  host=${authority%%:*}
  case "$host" in
    example.com|*.example.com|example.org|*.example.org|example.net|*.example.net|example|*.example|invalid|*.invalid)
      return 1
      ;;
  esac
}

toml_escape() {
  local value=${1-}
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

state_get() {
  local name=${1:?state field required}
  [[ "$name" =~ ^[a-z_]+$ ]] || return 1
  [[ -r "$active_dir/$name" ]] || return 1
  IFS= read -r CODEX_RP_STATE_VALUE < "$active_dir/$name"
}

state_put() {
  local directory=${1:?state directory required}
  local name=${2:?state field required}
  local value=${3-}
  [[ "$name" =~ ^[a-z_]+$ ]] || return 1
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  printf '%s\n' "$value" > "$directory/$name"
  chmod 600 "$directory/$name"
}

strip_managed_block() {
  local source_file=${1:?source file required}
  local target_file=${2:?target file required}
  local provider_id=${3:?provider id required}
  awk -v begin="# BEGIN codex-remote-provider-kit:$provider_id" \
      -v end="# END codex-remote-provider-kit:$provider_id" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$source_file" > "$target_file"
}

set_top_level_string_portable() {
  local target=${1:?config file required}
  local key=${2:?key required}
  local value=${3:?value required}
  local temp_file
  temp_file=$(make_target_temp "$target")
  awk -v key="$key" -v value="$value" '
    BEGIN { in_top=1; wrote=0 }
    in_top && /^[[:space:]]*\[/ {
      if (!wrote) { print key " = \"" value "\""; wrote=1 }
      in_top=0
    }
    in_top && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (!wrote) { print key " = \"" value "\""; wrote=1 }
      next
    }
    { print }
    END { if (in_top && !wrote) print key " = \"" value "\"" }
  ' "$target" > "$temp_file"
  chmod 600 "$temp_file"
  mv -f "$temp_file" "$target"
}

remove_top_level_key_portable() {
  local target=${1:?config file required}
  local key=${2:?key required}
  local temp_file
  temp_file=$(make_target_temp "$target")
  awk -v key="$key" '
    BEGIN { in_top=1 }
    in_top && /^[[:space:]]*\[/ { in_top=0 }
    in_top && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { next }
    { print }
  ' "$target" > "$temp_file"
  chmod 600 "$temp_file"
  mv -f "$temp_file" "$target"
}

top_level_string() {
  local target=${1:?config file required}
  local key=${2:?key required}
  awk -v key="$key" '
    BEGIN { in_top=1 }
    in_top && /^[[:space:]]*\[/ { exit }
    in_top && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line=$0
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*\"", "", line)
      sub("\"[[:space:]]*([#].*)?$", "", line)
      print line
      exit
    }
  ' "$target"
}

top_level_assignment() {
  local target=${1:?config file required}
  local key=${2:?key required}
  [[ -f "$target" ]] || return 1
  awk -v key="$key" '
    BEGIN { in_top=1; found=0 }
    in_top && /^[[:space:]]*\[/ { exit }
    in_top && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      print
      found=1
      exit
    }
    END { if (!found) exit 1 }
  ' "$target"
}

restore_top_level_assignment_from_backup() {
  local target=${1:?config file required}
  local backup=${2:?backup file required}
  local key=${3:?key required}
  local temp_file
  temp_file=$(make_target_temp "$target")
  awk -v key="$key" -v backup_file="$backup" '
    BEGIN {
      backup_top=1
      found=0
      while ((getline backup_line < backup_file) > 0) {
        if (backup_top && backup_line ~ /^[[:space:]]*\[/) backup_top=0
        if (backup_top && backup_line ~ "^[[:space:]]*" key "[[:space:]]*=") {
          assignment=backup_line
          found=1
          break
        }
      }
      close(backup_file)
      in_top=1
      wrote=0
    }
    in_top && /^[[:space:]]*\[/ {
      if (!wrote && found) { print assignment; wrote=1 }
      in_top=0
    }
    in_top && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (!wrote && found) { print assignment; wrote=1 }
      next
    }
    { print }
    END { if (in_top && !wrote && found) print assignment }
  ' "$target" > "$temp_file"
  chmod 600 "$temp_file"
  mv -f "$temp_file" "$target"
}

set_third_party_defaults() {
  local selected_provider=${1:?provider required}
  local selected_model=${2:?model required}
  local selected_reasoning=${3:?reasoning required}
  local work_file
  mkdir -p "$codex_home"
  work_file=$(make_target_temp "$config_file")
  if ! {
    if [[ -f "$config_file" ]]; then cp "$config_file" "$work_file"; else : > "$work_file"; fi
    set_top_level_string_portable "$work_file" model_provider "$selected_provider"
    set_top_level_string_portable "$work_file" model "$selected_model"
    set_top_level_string_portable "$work_file" model_reasoning_effort "$selected_reasoning"
    chmod 600 "$work_file"
    mv -f "$work_file" "$config_file"
  }; then
    rm -f "$work_file"
    return 1
  fi
}

restore_official_defaults() {
  local backup_file="$active_dir/backup/config.toml"
  local key work_file
  mkdir -p "$codex_home"
  work_file=$(make_target_temp "$config_file")
  if ! {
    if [[ -f "$config_file" ]]; then cp "$config_file" "$work_file"; else : > "$work_file"; fi
    for key in model_provider model model_reasoning_effort; do
      restore_top_level_assignment_from_backup "$work_file" "$backup_file" "$key"
    done
    chmod 600 "$work_file"
    mv -f "$work_file" "$config_file"
  }; then
    rm -f "$work_file"
    return 1
  fi
}

official_defaults_match() {
  local backup_file="$active_dir/backup/config.toml"
  local key current_assignment backup_assignment current_present backup_present
  for key in model_provider model model_reasoning_effort; do
    current_present=no
    backup_present=no
    if current_assignment=$(top_level_assignment "$config_file" "$key"); then current_present=yes; fi
    if backup_assignment=$(top_level_assignment "$backup_file" "$key"); then backup_present=yes; fi
    [[ "$current_present" == "$backup_present" ]] || return 1
    [[ "$current_present" == no || "$current_assignment" == "$backup_assignment" ]] || return 1
  done
}

load_state() {
  [[ -d "$active_dir" ]] || die '尚未安装 macOS provider 配置'
  state_get provider_id || die '状态缺少 provider_id'; provider_id=$CODEX_RP_STATE_VALUE
  state_get model || die '状态缺少 model'; model=$CODEX_RP_STATE_VALUE
  state_get reasoning || die '状态缺少 reasoning'; reasoning=$CODEX_RP_STATE_VALUE
  state_get base_url || die '状态缺少 base_url'; base_url=$CODEX_RP_STATE_VALUE
  state_get keychain_service || die '状态缺少 keychain_service'; keychain_service=$CODEX_RP_STATE_VALUE
  if state_get keychain_account; then
    keychain_account=$CODEX_RP_STATE_VALUE
  else
    # 兼容尚未记录 Keychain account 的早期 macOS 安装状态。
    keychain_account=$provider_id
  fi
  state_get codex_bin || die '状态缺少 codex_bin'; codex_bin=$CODEX_RP_STATE_VALUE
  profile_file="$codex_home/$provider_id.config.toml"
}

keychain_store() {
  local account=${1:?keychain account required}
  local service=${2:?keychain service required}
  local value=${3:?keychain value required}
  printf 'add-generic-password -U -a %s -s %s -w %s\n' \
    "$account" "$service" "$value" | "$security_bin" -i >/dev/null
}

ensure_launcher() {
  local launcher_dir temp_file
  launcher_dir=$(dirname "$launcher_file")
  if [[ -e "$launcher_file" ]] && ! grep -Fxq "$launcher_marker" "$launcher_file"; then
    die "$launcher_file 已存在，且不由本套件管理"
  fi
  mkdir -p "$launcher_dir"
  temp_file=$(make_target_temp "$launcher_file")
  if ! {
    {
      printf '#!/usr/bin/env bash\n'
      printf '%s\n' "$launcher_marker"
      printf 'exec %q "$@"\n' "$script_dir/codex-rp.sh"
    } > "$temp_file"
    chmod 755 "$temp_file"
    mv -f "$temp_file" "$launcher_file"
  }; then
    rm -f "$temp_file"
    return 1
  fi
}

check_launcher_target() {
  if [[ -e "$launcher_file" ]] && ! grep -Fxq "$launcher_marker" "$launcher_file"; then
    die "$launcher_file 已存在，且不由本套件管理"
  fi
}

app_bundle_is_managed() {
  local bundle=${1:?app bundle required}
  [[ -f "$bundle/Contents/Resources/.codex-rp-managed" ]] \
    && grep -Fxq "$app_launcher_marker" \
      "$bundle/Contents/Resources/.codex-rp-managed"
}

app_launcher_is_managed() {
  app_bundle_is_managed "$app_launcher"
}

migrate_legacy_app_launcher() {
  [[ -n "$legacy_app_launcher" && -e "$legacy_app_launcher" ]] || return 0
  [[ ! -L "$legacy_app_launcher" ]] || return 0
  app_bundle_is_managed "$legacy_app_launcher" || return 0
  mkdir -p "$(dirname "$app_launcher")"
  if [[ -e "$app_launcher" ]]; then
    app_launcher_is_managed \
      || die "$app_launcher 已存在，且不由本套件管理；无法迁移英文快捷入口"
    rm -rf "$legacy_app_launcher"
  else
    mv "$legacy_app_launcher" "$app_launcher"
  fi
}

check_app_launcher_target() {
  case "$app_launcher" in
    /*/*.app) ;;
    *) die 'macOS 快捷入口必须是绝对路径下的 .app 目录' ;;
  esac
  [[ ! -L "$app_launcher" ]] || die "$app_launcher 是符号链接，已拒绝覆盖"
  if [[ -e "$app_launcher" ]] && ! app_launcher_is_managed; then
    die "$app_launcher 已存在，且不由本套件管理"
  fi
}

ensure_app_launcher() {
  local app_parent temp_bundle old_bundle executable_file resources_dir icon_source
  migrate_legacy_app_launcher
  check_app_launcher_target
  icon_source="$script_dir/assets/codex-rp.icns"
  [[ -f "$icon_source" ]] || die "macOS 图标资源缺失：$icon_source"
  app_parent=$(dirname "$app_launcher")
  mkdir -p "$app_parent"
  temp_bundle=$(mktemp -d "$app_parent/.codex-rp-app.XXXXXX")
  old_bundle=''
  executable_file="$temp_bundle/Contents/MacOS/codex-rp-launcher"
  resources_dir="$temp_bundle/Contents/Resources"
  mkdir -p "$(dirname "$executable_file")" "$resources_dir"

  cat > "$temp_bundle/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Codex 远程模型服务工具</string>
  <key>CFBundleExecutable</key>
  <string>codex-rp-launcher</string>
  <key>CFBundleIdentifier</key>
  <string>com.forcemind.codex-remote-provider-kit</string>
  <key>CFBundleIconFile</key>
  <string>codex-rp.icns</string>
  <key>CFBundleName</key>
  <string>Codex 远程模型服务工具</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.15</string>
</dict>
</plist>
EOF
  cp -p "$icon_source" "$resources_dir/codex-rp.icns"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec %q menu\n' "$script_dir/codex-rp.sh"
  } > "$resources_dir/launch.command"
  printf '%s\n' "$app_launcher_marker" > "$resources_dir/.codex-rp-managed"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'command_file=$(cd -- "$(dirname -- "$0")/../Resources" && pwd -P)/launch.command\n'
    printf 'exec /usr/bin/open -a Terminal "$command_file"\n'
  } > "$executable_file"
  chmod 755 "$executable_file" "$resources_dir/launch.command"
  chmod 644 "$temp_bundle/Contents/Info.plist" \
    "$resources_dir/.codex-rp-managed" "$resources_dir/codex-rp.icns"

  if [[ -e "$app_launcher" ]]; then
    [[ ! -L "$app_launcher" ]] && app_launcher_is_managed || {
      rm -rf "$temp_bundle"
      die "$app_launcher 在刷新前被替换为非套件内容，已取消"
    }
    old_bundle="$app_parent/.codex-rp-app.old.$$"
    [[ ! -e "$old_bundle" ]] || {
      rm -rf "$temp_bundle"
      die '发现残留的 macOS 快捷入口备份'
    }
    mv "$app_launcher" "$old_bundle"
  fi
  if ! mv "$temp_bundle" "$app_launcher"; then
    [[ -z "$old_bundle" || ! -e "$old_bundle" ]] || mv "$old_bundle" "$app_launcher"
    rm -rf "$temp_bundle"
    return 1
  fi
  [[ -z "$old_bundle" || ! -e "$old_bundle" ]] || rm -rf "$old_bundle"
  touch "$app_launcher"
}

install_shortcuts() {
  ensure_launcher
  ensure_app_launcher
  printf '快捷启动已安装：%s\n' "$app_launcher"
  printf '可从 Finder/Spotlight 打开，或拖到 Dock；终端命令仍为 codex-rp。\n'
}

find_codex() {
  local override=${1-}
  local candidate
  if [[ -n "$override" && -x "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  candidate=$(command -v codex 2>/dev/null || true)
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in "$HOME/.local/bin/codex" /usr/local/bin/codex /opt/homebrew/bin/codex; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_codex() {
  local override=${1-}
  if codex_bin=$(find_codex "$override"); then
    return 0
  fi
  [[ ${CODEX_RP_SKIP_CODEX_INSTALL:-0} != 1 ]] || die '测试模式下未找到 Codex CLI'
  command -v curl >/dev/null 2>&1 || die '缺少 curl，无法安装 Codex'
  printf '未检测到 Codex CLI，正在运行 OpenAI 官方 macOS 安装器……\n'
  curl -fsSL https://chatgpt.com/codex/install.sh | sh
  hash -r
  codex_bin=$(find_codex '') || die 'Codex 安装完成，但仍未找到 codex 命令'
}

install_provider() {
  local base_url='' model='gpt-5.6-sol' provider_id='third_party'
  local reasoning='high' codex_override='' api_key='' input
  local staging_dir source_config stripped_config new_config profile_temp
  local keychain_service keychain_account
  local config_existed='no' profile_existed='no' profile_file escaped_security
  local launcher_existed='no' launcher_changed='no' keychain_written='no'
  local app_launcher_existed='no' app_launcher_changed='no'

  while (($#)); do
    case "$1" in
      --base-url) base_url=${2:?}; shift 2 ;;
      --model) model=${2:?}; shift 2 ;;
      --provider-id) provider_id=${2:?}; shift 2 ;;
      --reasoning) reasoning=${2:?}; shift 2 ;;
      --codex-bin) codex_override=${2:?}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) die "未知安装参数：$1" ;;
    esac
  done

  [[ ! -d "$active_dir" ]] || die '已经安装；请使用 third-party、official、rotate-key 或 rollback'
  validate_provider_id "$provider_id" || die 'Provider ID 无效'
  validate_model "$model" || die '模型名称无效'
  validate_reasoning "$reasoning" || die '推理强度无效'

  if [[ -z "$base_url" ]]; then
    [[ -t 0 ]] || die '非交互安装必须提供 --base-url'
    printf '请输入真实第三方 Base URL（示例：https://api.example.com/v1）：'
    read -r base_url
  fi
  base_url=${base_url%/}
  validate_base_url "$base_url" || die 'Base URL 必须是非示例 HTTPS 地址，且不能包含凭据、查询或片段'

  ensure_codex "$codex_override"
  check_launcher_target
  migrate_legacy_app_launcher
  check_app_launcher_target
  keychain_service="codex-remote-provider-kit:$provider_id"
  keychain_account=$provider_id
  if "$security_bin" find-generic-password -a "$keychain_account" \
      -s "$keychain_service" >/dev/null 2>&1; then
    die "Keychain 已存在同名条目：$keychain_service；请先确认或回滚"
  fi

  api_key=${THIRD_PARTY_API_KEY-}
  if [[ -z "$api_key" ]]; then
    [[ -t 0 ]] || die '非交互安装需要通过受控环境注入 THIRD_PARTY_API_KEY'
    read -rsp '请输入第三方 API 密钥（不会回显）：' api_key
    printf '\n'
    [[ -n "$api_key" ]] && printf '已收到 API 密钥（%d 个字符，内容已隐藏）。\n' "${#api_key}"
  fi
  validate_api_key "$api_key" || die 'API 密钥包含不支持的字符'

  mkdir -p "$codex_home" "$data_dir" "$audit_dir"
  chmod 700 "$codex_home" "$data_dir" "$audit_dir" 2>/dev/null || true
  staging_dir="$data_dir/active.new.$$"
  [[ ! -e "$staging_dir" ]] || die '发现残留的安装暂存目录'
  mkdir -p "$staging_dir/backup"
  chmod 700 "$staging_dir" "$staging_dir/backup"
  profile_file="$codex_home/$provider_id.config.toml"

  if [[ -f "$config_file" ]]; then
    config_existed='yes'
    cp -p "$config_file" "$staging_dir/backup/config.toml"
  fi
  if [[ -f "$profile_file" ]]; then
    profile_existed='yes'
    cp -p "$profile_file" "$staging_dir/backup/profile.config.toml"
  fi
  if [[ -f "$launcher_file" ]]; then
    launcher_existed='yes'
    cp -p "$launcher_file" "$staging_dir/backup/codex-rp-launcher"
  fi
  if [[ -d "$app_launcher" ]]; then
    app_launcher_existed='yes'
    cp -pR "$app_launcher" "$staging_dir/backup/codex-rp-app"
  fi

  source_config=$(make_temp)
  if [[ "$config_existed" == yes ]]; then
    cp "$config_file" "$source_config"
  else
    : > "$source_config"
  fi
  stripped_config=$(make_temp)
  new_config=$(make_temp)
  profile_temp=$(make_temp)
  cleanup_install() {
    rm -f "$source_config" "$stripped_config" "$new_config" "$profile_temp"
    rm -rf "$staging_dir"
  }
  trap cleanup_install EXIT
  strip_managed_block "$source_config" "$stripped_config" "$provider_id"
  if grep -Eq "^[[:space:]]*\[model_providers\.${provider_id}\][[:space:]]*$" "$stripped_config"; then
    die "配置已在套件管理区块之外定义 model_providers.$provider_id"
  fi
  cp "$stripped_config" "$new_config"
  set_top_level_string_portable "$new_config" model_provider "$provider_id"
  set_top_level_string_portable "$new_config" model "$model"
  set_top_level_string_portable "$new_config" model_reasoning_effort "$reasoning"
  escaped_security=$(toml_escape "$security_bin")
  cat >> "$new_config" <<EOF

# BEGIN codex-remote-provider-kit:$provider_id
[model_providers.$provider_id]
name = "$provider_id"
base_url = "$base_url"
wire_api = "responses"

[model_providers.$provider_id.auth]
command = "$escaped_security"
args = ["find-generic-password", "-a", "$keychain_account", "-s", "$keychain_service", "-w"]
# END codex-remote-provider-kit:$provider_id
EOF
  cat > "$profile_temp" <<EOF
model = "$model"
model_provider = "$provider_id"
model_reasoning_effort = "$reasoning"
EOF
  chmod 600 "$new_config" "$profile_temp"

  state_put "$staging_dir" provider_id "$provider_id"
  state_put "$staging_dir" model "$model"
  state_put "$staging_dir" reasoning "$reasoning"
  state_put "$staging_dir" base_url "$base_url"
  state_put "$staging_dir" keychain_service "$keychain_service"
  state_put "$staging_dir" keychain_account "$keychain_account"
  state_put "$staging_dir" codex_bin "$codex_bin"
  state_put "$staging_dir" config_existed "$config_existed"
  state_put "$staging_dir" profile_existed "$profile_existed"
  state_put "$staging_dir" launcher_existed "$launcher_existed"
  state_put "$staging_dir" app_launcher_existed "$app_launcher_existed"

  install_failed='yes'
  rollback_partial_install() {
    local exit_status=$?
    local recovery_failed='no'
    trap - ERR
    trap - EXIT
    set +e
    if [[ ${install_failed:-no} == yes ]]; then
      if [[ "$keychain_written" == yes ]]; then
        "$security_bin" delete-generic-password -a "$keychain_account" \
          -s "$keychain_service" >/dev/null 2>&1 \
          || recovery_failed='yes'
      fi
      if [[ "$config_existed" == yes ]]; then
        cp -p "$staging_dir/backup/config.toml" "$config_file" || recovery_failed='yes'
      else
        rm -f "$config_file" || recovery_failed='yes'
      fi
      if [[ "$profile_existed" == yes ]]; then
        cp -p "$staging_dir/backup/profile.config.toml" "$profile_file" || recovery_failed='yes'
      else
        rm -f "$profile_file" || recovery_failed='yes'
      fi
      if [[ "$launcher_changed" == yes ]]; then
        if [[ "$launcher_existed" == yes ]]; then
          cp -p "$staging_dir/backup/codex-rp-launcher" "$launcher_file" || recovery_failed='yes'
        elif [[ -f "$launcher_file" ]] && grep -Fxq "$launcher_marker" "$launcher_file"; then
          rm -f "$launcher_file" || recovery_failed='yes'
        else
          recovery_failed='yes'
        fi
      fi
      if [[ "$app_launcher_changed" == yes ]]; then
        if [[ "$app_launcher_existed" == yes ]]; then
          if [[ -e "$app_launcher" ]] && ! app_launcher_is_managed; then
            recovery_failed='yes'
          else
            rm -rf "$app_launcher"
            cp -pR "$staging_dir/backup/codex-rp-app" "$app_launcher" \
              || recovery_failed='yes'
          fi
        elif app_launcher_is_managed; then
          rm -rf "$app_launcher" || recovery_failed='yes'
        else
          recovery_failed='yes'
        fi
      fi
      rm -f "$source_config" "$stripped_config" "$new_config" "$profile_temp"
      if [[ "$recovery_failed" == no ]]; then
        rm -rf "$staging_dir"
        printf '安装失败；已恢复原配置并删除新建的 Keychain 条目。\n' >&2
      else
        printf '安装失败且自动恢复不完整；备份暂存目录已保留：%s\n' "$staging_dir" >&2
      fi
    fi
    exit "$exit_status"
  }
  trap rollback_partial_install ERR

  keychain_written='yes'
  keychain_store "$keychain_account" "$keychain_service" "$api_key"
  api_key=''
  install -m 600 "$new_config" "$config_file"
  install -m 600 "$profile_temp" "$profile_file"
  ensure_launcher
  launcher_changed='yes'
  ensure_app_launcher
  app_launcher_changed='yes'
  mv "$staging_dir" "$active_dir"
  install_failed='no'
  trap - ERR
  trap - EXIT
  cleanup_install

  printf 'macOS 第三方 provider 已安装：%s / %s\n' "$provider_id" "$model"
  printf '密钥已保存到本用户 macOS Keychain，未写入 config.toml。\n'
  printf '账号、workspace、Remote 配对和会话均未修改。\n'
  printf '请运行 codex-rp restart-app，再从手机新建会话验证。\n'
  printf '也可从 Finder/Spotlight 打开：%s\n' "$app_launcher"
}

use_third_party() {
  load_state
  set_third_party_defaults "$provider_id" "$model" "$reasoning"
  printf '已切换配置到第三方 provider：%s / %s。\n' "$provider_id" "$model"
  printf '未重启 ChatGPT，也未修改账号或 Remote 配对；请明确运行 codex-rp restart-app。\n'
}

use_official() {
  local confirmation
  load_state
  printf '此操作只恢复安装前的官方默认模型配置，可能使用官方额度。\n'
  printf '是否继续？[y/N]：'
  read -r confirmation
  case "$confirmation" in
    y|Y) ;;
    n|N|'') printf '操作已取消\n'; return 0 ;;
    *) die '请输入 y 或 n；操作已取消' ;;
  esac
  restore_official_defaults
  printf '已恢复安装前官方默认配置。Keychain、账号和 Remote 配对均未删除。\n'
  printf '请明确运行 codex-rp restart-app，再新建会话。\n'
}

show_status() {
  local actual_provider actual_model actual_reasoning keychain_status app_status login_status
  load_state
  actual_provider=$(top_level_string "$config_file" model_provider)
  actual_model=$(top_level_string "$config_file" model)
  actual_reasoning=$(top_level_string "$config_file" model_reasoning_effort)
  printf '[平台]\nmacOS\n'
  printf '[配置]\n'
  if [[ "$actual_provider" == "$provider_id" ]]; then
    printf '当前模式：third-party\n'
    [[ "$actual_model" == "$model" ]] || die "模型不匹配：$actual_model"
    [[ "$actual_reasoning" == "$reasoning" ]] || die "推理强度不匹配：$actual_reasoning"
  elif official_defaults_match; then
    printf '当前模式：official\n'
  else
    printf '当前模式：unmanaged\n'
    die '三项顶层默认配置既不匹配第三方模式，也不匹配安装前官方模式'
  fi
  printf '用户配置：%s\n' "$config_file"

  keychain_status='缺失'
  "$security_bin" find-generic-password -a "$keychain_account" \
    -s "$keychain_service" >/dev/null 2>&1 \
    && keychain_status='存在'
  printf '[凭据]\nKeychain 条目：%s\n' "$keychain_status"
  [[ "$keychain_status" == '存在' ]] || return 1

  printf '[Codex]\n'
  "$codex_bin" --version
  login_status=$({ "$codex_bin" login status 2>&1 || true; })
  if [[ "$login_status" == *'Logged in using ChatGPT'* ]]; then
    printf 'CLI 登录：已使用 ChatGPT 登录\n'
  else
    printf 'CLI 登录：未确认；请检查 ChatGPT 桌面应用是否登录正确账号/workspace\n'
  fi

  app_status='未运行'
  if command -v pgrep >/dev/null 2>&1 && pgrep -x ChatGPT >/dev/null 2>&1; then
    app_status='运行中'
  fi
  printf '[Remote 宿主]\nChatGPT 桌面应用：%s\n' "$app_status"
}

run_test() {
  local actual_provider last_message
  load_state
  actual_provider=$(top_level_string "$config_file" model_provider)
  [[ "$actual_provider" == "$provider_id" ]] || die '真实测试只在 third-party 模式运行'
  show_status
  last_message=$(make_temp)
  trap 'rm -f "$last_message"' EXIT
  printf '正在执行最小化第三方 Codex 回合，可能产生少量用量……\n'
  "$codex_bin" exec --strict-config --profile "$provider_id" --ephemeral \
    --skip-git-repo-check --sandbox read-only -C "${TMPDIR:-/tmp}" \
    --output-last-message "$last_message" 'Do not use tools. Reply exactly OK.' >/dev/null
  grep -qx 'OK' "$last_message" || die 'Codex 回复不是预期的 OK'
  rm -f "$last_message"
  trap - EXIT
  printf 'Codex 回复：OK\n'
}

rotate_key() {
  local api_key=''
  load_state
  [[ -t 0 ]] || die '密钥轮换必须在交互式终端运行'
  read -rsp '请输入新的第三方 API 密钥（不会回显）：' api_key
  printf '\n'
  validate_api_key "$api_key" || die 'API 密钥包含不支持的字符'
  keychain_store "$keychain_account" "$keychain_service" "$api_key"
  api_key=''
  printf 'Keychain 密钥已更新；请确认新密钥可用后立即吊销旧密钥。\n'
}

restart_app() {
  local confirmation attempt
  printf '这会暂时断开当前 Remote；不会注销账号或删除配对。请输入 RESTART_APP 继续：'
  read -r confirmation
  [[ "$confirmation" == RESTART_APP ]] || die '操作已取消'
  if [[ ${CODEX_RP_TEST_MODE:-0} == 1 ]]; then
    printf '测试模式：已模拟重启 ChatGPT。\n'
    return 0
  fi
  command -v osascript >/dev/null 2>&1 || die '未找到 osascript'
  command -v open >/dev/null 2>&1 || die '未找到 open'
  osascript -e 'tell application "ChatGPT" to quit' >/dev/null 2>&1 || true
  if command -v pgrep >/dev/null 2>&1; then
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      pgrep -x ChatGPT >/dev/null 2>&1 || break
      sleep 1
    done
    pgrep -x ChatGPT >/dev/null 2>&1 \
      && die 'ChatGPT 在 15 秒内未退出；当前应用未被强制终止，请手动重启'
  fi
  open -a ChatGPT
  printf 'ChatGPT 已重新打开；请等待 Remote 恢复后新建会话。\n'
}

rollback_all() {
  local confirmation config_existed profile_existed launcher_existed
  local app_launcher_existed timestamp target
  load_state
  printf '回滚会恢复安装前配置并删除本套件的 Keychain 密钥。请输入 ROLLBACK 继续：'
  read -r confirmation
  [[ "$confirmation" == ROLLBACK ]] || die '操作已取消'
  state_get config_existed; config_existed=$CODEX_RP_STATE_VALUE
  state_get profile_existed; profile_existed=$CODEX_RP_STATE_VALUE
  launcher_existed='no'
  if state_get launcher_existed; then
    launcher_existed=$CODEX_RP_STATE_VALUE
  elif [[ -f "$active_dir/backup/codex-rp-launcher" ]]; then
    # 兼容未记录 launcher_existed 的早期 macOS 安装。
    launcher_existed='yes'
  fi
  app_launcher_existed='no'
  if state_get app_launcher_existed; then
    app_launcher_existed=$CODEX_RP_STATE_VALUE
  elif [[ -d "$active_dir/backup/codex-rp-app" ]]; then
    app_launcher_existed='yes'
  fi
  if [[ "$app_launcher_existed" == yes && -e "$app_launcher" ]] \
      && ! app_launcher_is_managed; then
    die "$app_launcher 已被替换为非套件内容，已拒绝覆盖"
  fi
  if [[ "$config_existed" == yes ]]; then
    cp -p "$active_dir/backup/config.toml" "$config_file"
  else
    rm -f "$config_file"
  fi
  if [[ "$profile_existed" == yes ]]; then
    cp -p "$active_dir/backup/profile.config.toml" "$profile_file"
  else
    rm -f "$profile_file"
  fi
  if [[ "$launcher_existed" == yes ]]; then
    cp -p "$active_dir/backup/codex-rp-launcher" "$launcher_file"
  elif [[ -f "$launcher_file" ]] && grep -Fxq "$launcher_marker" "$launcher_file"; then
    rm -f "$launcher_file"
  fi
  if [[ "$app_launcher_existed" == yes ]]; then
    if [[ -e "$app_launcher" ]]; then
      rm -rf "$app_launcher"
    fi
    cp -pR "$active_dir/backup/codex-rp-app" "$app_launcher"
  elif app_launcher_is_managed; then
    rm -rf "$app_launcher"
  fi
  "$security_bin" delete-generic-password -a "$keychain_account" \
    -s "$keychain_service" >/dev/null 2>&1 || true
  mkdir -p "$audit_dir"
  timestamp=$(date +%Y%m%d-%H%M%S)
  target="$audit_dir/state-$timestamp-$$"
  mv "$active_dir" "$target"
  printf '回滚完成。账号、Remote 配对和会话未修改；审计备份：%s\n' "$target"
}

show_menu() {
  local choice
  ensure_launcher
  ensure_app_launcher
  while true; do
    printf '\nCodex 远程模型服务工具（macOS）\n'
    printf '1) 安装第三方 provider\n2) 查看状态\n3) 完整测试\n'
    printf '4) 切换第三方\n5) 切换官方\n6) 轮换密钥\n'
    printf '7) 重启 ChatGPT 应用\n8) 完整回滚\n'
    printf '9) 安装/刷新 Mac 快捷启动\n0) 退出\n请选择：'
    read -r choice || return 0
    case "$choice" in
      1) run_menu_command install ;;
      2) run_menu_command status ;;
      3) run_menu_command test ;;
      4) run_menu_command third-party ;;
      5) run_menu_command official ;;
      6) run_menu_command rotate-key ;;
      7) run_menu_command restart-app ;;
      8) run_menu_command rollback ;;
      9) run_menu_command shortcut ;;
      0) return 0 ;;
      *) printf '无效选项。\n' >&2 ;;
    esac
  done
}

run_menu_command() {
  local selected_command=${1:?menu command required}
  if "$script_dir/codex-rp.sh" "$selected_command"; then
    printf '操作完成，已返回主菜单。\n'
  else
    printf '操作失败，已返回主菜单。\n' >&2
  fi
}

command_name=${1:-menu}
if (($#)); then shift; fi
case "$command_name" in
  menu) show_menu "$@" ;;
  install) install_provider "$@" ;;
  status) (($# == 0)) || die 'status 不接受参数'; show_status ;;
  test) (($# == 0)) || die 'test 不接受参数'; run_test ;;
  official) (($# == 0)) || die 'official 不接受参数'; use_official ;;
  third-party) (($# == 0)) || die 'third-party 不接受参数'; use_third_party ;;
  rotate-key) (($# == 0)) || die 'rotate-key 不接受参数'; rotate_key ;;
  shortcut) (($# == 0)) || die 'shortcut 不接受参数'; install_shortcuts ;;
  restart-app) (($# == 0)) || die 'restart-app 不接受参数'; restart_app ;;
  rollback) (($# == 0)) || die 'rollback 不接受参数'; rollback_all ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "未知命令：$command_name" ;;
esac
