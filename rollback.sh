#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

((EUID == 0)) || { printf '请以 root 身份运行\n' >&2; exit 1; }
state_file=${CODEX_RP_STATE_FILE:-/var/lib/codex-remote-provider/state.env}
[[ -r "$state_file" ]] || { printf '缺少状态文件；没有可回滚的内容\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"
third_party_unit_file=${THIRD_PARTY_UNIT_FILE:-/etc/systemd/system/codex-remote-provider.service}
official_unit_file=${OFFICIAL_UNIT_FILE:-/etc/systemd/system/codex-remote-official.service}
third_party_unit_name=${third_party_unit_file##*/}
official_unit_name=${official_unit_file##*/}
secret_file=${CODEX_RP_SECRET_FILE:-/etc/codex-remote-provider/provider.env}

printf '回滚将删除持久化的供应商密钥，并从 %s 恢复配置。\n' "$BACKUP_DIR"
printf '请输入 ROLLBACK 继续：'
read -r confirmation
[[ "$confirmation" == 'ROLLBACK' ]] || { printf '操作已取消\n'; exit 1; }

systemctl disable --now "$third_party_unit_name" >/dev/null 2>&1 || true
systemctl disable --now "$official_unit_name" >/dev/null 2>&1 || true
"$CODEX_BIN_PATH" remote-control stop --json >/dev/null 2>&1 || true

if [[ -f "$BACKUP_DIR/config.toml" ]]; then
  install -m 600 "$BACKUP_DIR/config.toml" "$CODEX_HOME_DIR/config.toml"
else
  tmp_config=$(mktemp)
  awk -v begin="# BEGIN codex-remote-provider-kit:$PROVIDER_ID" \
      -v end="# END codex-remote-provider-kit:$PROVIDER_ID" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$CODEX_HOME_DIR/config.toml" > "$tmp_config"
  install -m 600 "$tmp_config" "$CODEX_HOME_DIR/config.toml"
  rm -f "$tmp_config"
  remove_top_level_key "$CODEX_HOME_DIR/config.toml" model_provider
  remove_top_level_key "$CODEX_HOME_DIR/config.toml" model
  remove_top_level_key "$CODEX_HOME_DIR/config.toml" model_reasoning_effort
fi

if [[ -f "$BACKUP_DIR/profile.config.toml" ]]; then
  install -m 600 "$BACKUP_DIR/profile.config.toml" "$CODEX_HOME_DIR/$PROVIDER_ID.config.toml"
else
  rm -f "$CODEX_HOME_DIR/$PROVIDER_ID.config.toml"
fi

rm -f "$secret_file"

if [[ -f "$BACKUP_DIR/codex-remote-provider.service" ]]; then
  install -m 644 "$BACKUP_DIR/codex-remote-provider.service" "$third_party_unit_file"
else
  rm -f "$third_party_unit_file"
fi
if [[ -f "$BACKUP_DIR/codex-remote-official.service" ]]; then
  install -m 644 "$BACKUP_DIR/codex-remote-official.service" "$official_unit_file"
else
  rm -f "$official_unit_file"
fi

command_file=${COMMAND_FILE:-/usr/local/bin/codex-rp}
if [[ -f "$BACKUP_DIR/codex-rp" ]]; then
  install -m 755 "$BACKUP_DIR/codex-rp" "$command_file"
elif [[ -f "$command_file" ]] && grep -Fxq '# Managed by codex-remote-provider-kit' "$command_file"; then
  rm -f "$command_file"
fi
systemctl daemon-reload

third_party_unit_existed=${THIRD_PARTY_UNIT_EXISTED:-no}
official_unit_existed=${OFFICIAL_UNIT_EXISTED:-no}
[[ -f "$BACKUP_DIR/codex-remote-provider.service" ]] && third_party_unit_existed='yes'
[[ -f "$BACKUP_DIR/codex-remote-official.service" ]] && official_unit_existed='yes'

if [[ "$third_party_unit_existed" == yes ]]; then
  if [[ ${THIRD_PARTY_UNIT_ENABLED:-no} == yes ]]; then
    systemctl enable "$third_party_unit_name"
  else
    systemctl disable "$third_party_unit_name" >/dev/null 2>&1 || true
  fi
  if [[ ${THIRD_PARTY_UNIT_ACTIVE:-no} == yes ]]; then
    systemctl start "$third_party_unit_name"
  fi
fi
if [[ "$official_unit_existed" == yes ]]; then
  if [[ ${OFFICIAL_UNIT_ENABLED:-no} == yes ]]; then
    systemctl enable "$official_unit_name"
  else
    systemctl disable "$official_unit_name" >/dev/null 2>&1 || true
  fi
  if [[ ${OFFICIAL_UNIT_ACTIVE:-no} == yes ]]; then
    systemctl start "$official_unit_name"
  fi
fi
if [[ "$LEGACY_ENABLED" == yes ]]; then systemctl enable codex.service; fi
if [[ "$LEGACY_ACTIVE" == yes ]]; then systemctl start codex.service; fi

audit_dir="$(dirname "$state_file")/audit"
install -d -m 700 "$audit_dir"
audit_file="$audit_dir/state-$(date +%Y%m%d-%H%M%S)-$$.env"
mv "$state_file" "$audit_file"
printf '回滚完成。审计用状态文件保留在 %s；现在可以重新安装。\n' "$audit_file"
