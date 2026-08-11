#!/usr/bin/env bash

is_root_only_regular_file() {
  local target_file=${1:?file required}
  local mode owner

  [[ -f "$target_file" && ! -L "$target_file" ]] || return 1
  mode=$(stat -c '%a' "$target_file") || return 1
  owner=$(stat -c '%u' "$target_file") || return 1
  [[ "$mode" == 600 && "$owner" == 0 ]]
}

is_root_only_directory() {
  local target_dir=${1:?directory required}
  local mode owner

  [[ -d "$target_dir" && ! -L "$target_dir" ]] || return 1
  mode=$(stat -c '%a' "$target_dir") || return 1
  owner=$(stat -c '%u' "$target_dir") || return 1
  [[ "$mode" == 700 && "$owner" == 0 ]]
}

is_root_owned_regular_file() {
  local target_file=${1:?file required}
  local owner

  [[ -f "$target_file" && ! -L "$target_file" ]] || return 1
  owner=$(stat -c '%u' "$target_file") || return 1
  [[ "$owner" == 0 ]]
}

is_root_owned_nonwritable_directory() {
  local target_dir=${1:?directory required}
  local mode owner numeric_mode

  [[ -d "$target_dir" && ! -L "$target_dir" ]] || return 1
  mode=$(stat -c '%a' "$target_dir") || return 1
  owner=$(stat -c '%u' "$target_dir") || return 1
  [[ "$owner" == 0 ]] || return 1
  numeric_mode=$((8#$mode))
  (( (numeric_mode & 0022) == 0 ))
}

path_has_symlink_component() {
  local target_path=${1:?path required}
  local current_path

  if [[ "$target_path" == /* ]]; then
    current_path=$target_path
  else
    current_path=$PWD/$target_path
  fi
  while :; do
    [[ ! -L "$current_path" ]] || return 0
    [[ "$current_path" != / ]] || break
    current_path=${current_path%/*}
    [[ -n "$current_path" ]] || current_path=/
  done
  return 1
}

paths_are_distinct() {
  local path canonical
  local -A seen=()

  (($# > 1)) || return 0
  for path in "$@"; do
    canonical=$(realpath -m -- "$path") || return 1
    [[ -z ${seen[$canonical]:-} ]] || return 1
    seen[$canonical]=1
  done
}

is_chatgpt_logged_in() {
  local codex_bin=${1:?Codex executable required}
  local login_status

  # Codex 0.147.0 writes the human-readable login status to stderr.
  login_status=$("$codex_bin" login status 2>&1) || return 1
  [[ "$login_status" == *'Logged in using ChatGPT'* ]]
}

is_supported_api_key() {
  local api_key=${1-}

  [[ -n "$api_key" ]] || return 1
  [[ "$api_key" != *$'\n'* && "$api_key" != *$'\r'* ]] || return 1
  # Accept common opaque, URL-safe, and padded Base64 token formats.
  [[ "$api_key" =~ ^[A-Za-z0-9._~+/=-]+$ ]]
}

provider_id_from_base_url() {
  local base_url=${1:?Base URL required}

  python3 - "$base_url" <<'PY'
import hashlib
import re
import sys
from urllib.parse import urlsplit, urlunsplit

raw = sys.argv[1].rstrip("/")
parsed = urlsplit(raw)
if parsed.scheme not in {"http", "https"} or not parsed.hostname:
    raise SystemExit("invalid provider Base URL")

host = parsed.hostname.lower()
try:
    port = parsed.port
except ValueError as exc:
    raise SystemExit(str(exc)) from exc
netloc = host if port is None else f"{host}:{port}"
path = parsed.path.rstrip("/")
canonical = urlunsplit((parsed.scheme.lower(), netloc, path, "", ""))
label = netloc + path
slug = re.sub(r"[^a-z0-9]+", "_", label.lower()).strip("_")
slug = slug[:48].rstrip("_") or "provider"
digest = hashlib.sha256(canonical.encode()).hexdigest()[:10]
print(f"{slug}_{digest}")
PY
}

provider_env_name_from_id() {
  local provider_id=${1:?provider ID required}
  local upper

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  upper=${provider_id^^}
  upper=${upper//-/_}
  printf 'CODEX_RP_%s_API_KEY\n' "$upper"
}

resolve_provider_storage() {
  local state_file=${1:?state file required}
  local active_secret_file=${2:?active secret file required}

  CODEX_RP_PROVIDERS_PATH=${CODEX_RP_PROVIDERS_DIR:-${PROVIDERS_DIR:-$(dirname "$state_file")/providers}}
  CODEX_RP_PROVIDER_SECRETS_PATH=${CODEX_RP_PROVIDER_SECRETS_DIR:-${PROVIDER_SECRETS_DIR:-$(dirname "$active_secret_file")/providers}}
}

provider_record_path() {
  local providers_dir=${1:?providers directory required}
  local provider_id=${2:?provider ID required}

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  printf '%s/%s.env\n' "$providers_dir" "$provider_id"
}

provider_secret_path() {
  local secrets_dir=${1:?provider secrets directory required}
  local provider_id=${2:?provider ID required}

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  printf '%s/%s.env\n' "$secrets_dir" "$provider_id"
}

write_provider_record() {
  local target_file=${1:?target file required}
  local provider_id=${2:?provider ID required}
  local env_name=${3:?environment variable name required}
  local base_url=${4:?Base URL required}
  local model=${5:?model required}
  local reasoning=${6:?reasoning effort required}
  local temp_file

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$reasoning" =~ ^(none|minimal|low|medium|high|xhigh)$ ]] || return 1
  [[ -d "$(dirname "$target_file")" \
      && ! -L "$(dirname "$target_file")" ]] || return 1
  temp_file=$(mktemp "$(dirname "$target_file")/.provider.XXXXXX") || return 1
  if ! {
    printf 'PROVIDER_ID=%q\n' "$provider_id" \
      && printf 'ENV_NAME=%q\n' "$env_name" \
      && printf 'BASE_URL=%q\n' "${base_url%/}" \
      && printf 'MODEL=%q\n' "$model" \
      && printf 'REASONING=%q\n' "$reasoning"
  } > "$temp_file"; then
    rm -f "$temp_file" || true
    return 1
  fi
  if ! chmod 600 "$temp_file" || ! mv -f "$temp_file" "$target_file"; then
    rm -f "$temp_file" || true
    return 1
  fi
}

load_provider_record() {
  local record_file=${1:?provider record required}
  local expected_provider_id=${2-}

  is_root_only_regular_file "$record_file" || return 1
  unset PROVIDER_ID ENV_NAME BASE_URL MODEL REASONING
  # Provider records are root-owned files generated by write_provider_record.
  # shellcheck disable=SC1090
  source "$record_file" || return 1
  [[ "$PROVIDER_ID" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  [[ -z "$expected_provider_id" || "$PROVIDER_ID" == "$expected_provider_id" ]] || return 1
  [[ "$ENV_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [[ "$BASE_URL" =~ ^https?://[^[:space:]]+$ ]] || return 1
  [[ "$MODEL" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$REASONING" =~ ^(none|minimal|low|medium|high|xhigh)$ ]] || return 1
}

provider_record_matches() (
  local record_file=${1:?provider record required}
  local provider_id=${2:?provider ID required}
  local env_name=${3:?environment variable required}
  local base_url=${4:?Base URL required}
  local model=${5:?model required}
  local reasoning=${6:?reasoning required}

  load_provider_record "$record_file" "$provider_id" || return 1
  [[ "$ENV_NAME" == "$env_name" ]] || return 1
  [[ "${BASE_URL%/}" == "${base_url%/}" ]] || return 1
  [[ "$MODEL" == "$model" && "$REASONING" == "$reasoning" ]]
)

provider_profile_matches() {
  local profile_file=${1:?profile file required}
  local provider_id=${2:?provider ID required}
  local model=${3:?model required}
  local reasoning=${4:?reasoning required}
  local marker_required=${5:-no}
  local expected_marker first_line

  [[ -f "$profile_file" && ! -L "$profile_file" ]] || return 1
  [[ "$marker_required" =~ ^(yes|no)$ ]] || return 1
  expected_marker="# Managed by codex-remote-provider-kit:$provider_id"
  IFS= read -r first_line < "$profile_file" || return 1
  if [[ "$marker_required" == yes ]]; then
    [[ "$first_line" == "$expected_marker" ]] || return 1
  elif [[ "$first_line" == '# Managed by codex-remote-provider-kit:'* ]]; then
    [[ "$first_line" == "$expected_marker" ]] || return 1
  fi
  python3 - "$profile_file" "$provider_id" "$model" "$reasoning" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    profile = tomllib.load(handle)

expected = {
    "model_provider": sys.argv[2],
    "model": sys.argv[3],
    "model_reasoning_effort": sys.argv[4],
}
if set(profile) != set(expected):
    raise SystemExit(1)
if any(profile.get(key) != value for key, value in expected.items()):
    raise SystemExit(1)
PY
}

managed_provider_artifacts_match() (
  local providers_dir=${1:?providers directory required}
  local secrets_dir=${2:?provider secrets directory required}
  local codex_home=${3:?Codex home required}
  local provider_id=${4:?provider ID required}
  local marker_required=${5:-no}
  local record_file secret_file profile_file record_env record_model record_reasoning

  record_file=$(provider_record_path "$providers_dir" "$provider_id") || return 1
  secret_file=$(provider_secret_path "$secrets_dir" "$provider_id") || return 1
  profile_file="$codex_home/$provider_id.config.toml"
  [[ -f "$record_file" && ! -L "$record_file" ]] || return 1
  is_root_only_regular_file "$secret_file" || return 1
  load_provider_record "$record_file" "$provider_id" || return 1
  record_env=$ENV_NAME
  record_model=$MODEL
  record_reasoning=$REASONING
  read_secret_environment_value "$secret_file" "$record_env" || return 1
  provider_profile_matches "$profile_file" "$provider_id" \
    "$record_model" "$record_reasoning" "$marker_required"
)

load_managed_provider_ids() {
  local provider_id
  local -a candidates=()
  local -A seen=()

  [[ ${OWNERSHIP_SCHEMA:-} == 1 ]] || return 1
  [[ ${PROFILE_MARKERS_REQUIRED:-} =~ ^(yes|no)$ ]] || return 1
  read -r -a candidates <<< "${MANAGED_PROVIDER_IDS:-}"
  ((${#candidates[@]} > 0)) || return 1
  CODEX_RP_MANAGED_PROVIDER_IDS=()
  for provider_id in "${candidates[@]}"; do
    [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    [[ -z ${seen[$provider_id]:-} ]] || return 1
    seen[$provider_id]=1
    CODEX_RP_MANAGED_PROVIDER_IDS+=("$provider_id")
  done
}

provider_is_managed() {
  local wanted=${1:?provider ID required}
  local provider_id

  [[ "$wanted" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  load_managed_provider_ids || return 1
  for provider_id in "${CODEX_RP_MANAGED_PROVIDER_IDS[@]}"; do
    [[ "$provider_id" == "$wanted" ]] && return 0
  done
  return 1
}

add_managed_provider_id() {
  local state_file=${1:?state file required}
  local provider_id=${2:?provider ID required}
  local existing joined

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  load_managed_provider_ids || return 1
  for existing in "${CODEX_RP_MANAGED_PROVIDER_IDS[@]}"; do
    [[ "$existing" == "$provider_id" ]] && return 0
  done
  CODEX_RP_MANAGED_PROVIDER_IDS+=("$provider_id")
  joined=${CODEX_RP_MANAGED_PROVIDER_IDS[*]}
  set_state_variable "$state_file" MANAGED_PROVIDER_IDS "$joined" || return 1
  MANAGED_PROVIDER_IDS=$joined
}

remove_managed_provider_id() {
  local state_file=${1:?state file required}
  local provider_id=${2:?provider ID required}
  local existing joined
  local -a retained=()

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  load_managed_provider_ids || return 1
  for existing in "${CODEX_RP_MANAGED_PROVIDER_IDS[@]}"; do
    [[ "$existing" == "$provider_id" ]] || retained+=("$existing")
  done
  ((${#retained[@]} > 0)) || return 1
  CODEX_RP_MANAGED_PROVIDER_IDS=("${retained[@]}")
  joined=${CODEX_RP_MANAGED_PROVIDER_IDS[*]}
  set_state_variable "$state_file" MANAGED_PROVIDER_IDS "$joined" || return 1
  MANAGED_PROVIDER_IDS=$joined
}

sync_current_provider_registry() {
  local state_file=${1:?state file required}
  local active_secret_file=${2:?active secret file required}
  local record_file stored_secret_file
  local providers_dir_existed='no' provider_secrets_dir_existed='no'
  local providers_dir_created='no' provider_secrets_dir_created='no'
  local installed_profile_preexisted='no'

  CODEX_RP_REGISTRY_WRITE_STARTED='no'

  [[ "$PROVIDER_ID" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  [[ "$ENV_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [[ "$BASE_URL" =~ ^https?://[^[:space:]]+$ ]] || return 1
  [[ "$BASE_URL" != *\"* && "$BASE_URL" != *\\* ]] || return 1
  [[ "$MODEL" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$REASONING" =~ ^(none|minimal|low|medium|high|xhigh)$ ]] || return 1
  is_root_only_regular_file "$active_secret_file" || return 1
  read_secret_environment_value "$active_secret_file" "$ENV_NAME" || return 1

  resolve_provider_storage "$state_file" "$active_secret_file" || return 1
  [[ -d "$CODEX_RP_PROVIDERS_PATH" ]] && providers_dir_existed='yes'
  [[ -d "$CODEX_RP_PROVIDER_SECRETS_PATH" ]] && provider_secrets_dir_existed='yes'
  if [[ -e "$CODEX_RP_PROVIDERS_PATH" || -L "$CODEX_RP_PROVIDERS_PATH" ]]; then
    is_root_only_directory "$CODEX_RP_PROVIDERS_PATH" || return 1
  fi
  if [[ -e "$CODEX_RP_PROVIDER_SECRETS_PATH" \
      || -L "$CODEX_RP_PROVIDER_SECRETS_PATH" ]]; then
    is_root_only_directory "$CODEX_RP_PROVIDER_SECRETS_PATH" || return 1
  fi
  [[ "$providers_dir_existed" == yes ]] || providers_dir_created='yes'
  [[ "$provider_secrets_dir_existed" == yes ]] || provider_secrets_dir_created='yes'
  record_file=$(provider_record_path "$CODEX_RP_PROVIDERS_PATH" "$PROVIDER_ID") \
    || return 1
  stored_secret_file=$(provider_secret_path \
    "$CODEX_RP_PROVIDER_SECRETS_PATH" "$PROVIDER_ID") || return 1

  if [[ -v OWNERSHIP_SCHEMA ]]; then
    [[ "$OWNERSHIP_SCHEMA" == 1 ]] || return 1
    provider_is_managed "$PROVIDER_ID" || return 1
    [[ -f "$record_file" && ! -L "$record_file" ]] || return 1
    [[ -f "$stored_secret_file" && ! -L "$stored_secret_file" ]] || return 1
    provider_record_matches "$record_file" "$PROVIDER_ID" "$ENV_NAME" \
      "$BASE_URL" "$MODEL" "$REASONING" || return 1
    cmp -s "$active_secret_file" "$stored_secret_file" || return 1
  else
    [[ ! -e "$record_file" && ! -L "$record_file" ]] || return 1
    [[ ! -e "$stored_secret_file" && ! -L "$stored_secret_file" ]] || return 1
  fi

  CODEX_RP_REGISTRY_WRITE_STARTED='yes'
  install -d -m 700 "$CODEX_RP_PROVIDERS_PATH" \
    "$CODEX_RP_PROVIDER_SECRETS_PATH" || return 1
  write_provider_record "$record_file" "$PROVIDER_ID" "$ENV_NAME" \
    "$BASE_URL" "$MODEL" "$REASONING" || return 1
  install -m 600 "$active_secret_file" "$stored_secret_file" || return 1
  set_state_variable "$state_file" PROVIDERS_DIR \
    "$CODEX_RP_PROVIDERS_PATH" || return 1
  set_state_variable "$state_file" PROVIDER_SECRETS_DIR \
    "$CODEX_RP_PROVIDER_SECRETS_PATH" || return 1
  if [[ -z ${INSTALLED_PROVIDER_ID:-} ]]; then
    set_state_variable "$state_file" INSTALLED_PROVIDER_ID "$PROVIDER_ID" \
      || return 1
    INSTALLED_PROVIDER_ID=$PROVIDER_ID
  fi
  if [[ ! -v OWNERSHIP_SCHEMA ]]; then
    [[ -n ${BACKUP_DIR:-} && -f "$BACKUP_DIR/profile.config.toml" ]] \
      && installed_profile_preexisted='yes'
    set_state_variable "$state_file" OWNERSHIP_SCHEMA 1 || return 1
    set_state_variable "$state_file" MANAGED_PROVIDER_IDS "$PROVIDER_ID" || return 1
    set_state_variable "$state_file" PROVIDERS_DIR_CREATED_BY_KIT \
      "$providers_dir_created" || return 1
    set_state_variable "$state_file" PROVIDER_SECRETS_DIR_CREATED_BY_KIT \
      "$provider_secrets_dir_created" || return 1
    set_state_variable "$state_file" INSTALLED_PROFILE_PREEXISTED \
      "$installed_profile_preexisted" || return 1
    set_state_variable "$state_file" PROFILE_MARKERS_REQUIRED no || return 1
    OWNERSHIP_SCHEMA=1
    MANAGED_PROVIDER_IDS=$PROVIDER_ID
    PROVIDERS_DIR_CREATED_BY_KIT=$providers_dir_created
    PROVIDER_SECRETS_DIR_CREATED_BY_KIT=$provider_secrets_dir_created
    INSTALLED_PROFILE_PREEXISTED=$installed_profile_preexisted
    PROFILE_MARKERS_REQUIRED=no
  fi
}

set_active_provider_state() {
  local state_file=${1:?state file required}
  local provider_id=${2:?provider ID required}
  local env_name=${3:?environment variable name required}
  local base_url=${4:?Base URL required}
  local model=${5:?model required}
  local reasoning=${6:?reasoning effort required}

  set_state_variable "$state_file" PROVIDER_ID "$provider_id" || return 1
  set_state_variable "$state_file" ENV_NAME "$env_name" || return 1
  set_state_variable "$state_file" BASE_URL "${base_url%/}" || return 1
  set_state_variable "$state_file" MODEL "$model" || return 1
  set_state_variable "$state_file" REASONING "$reasoning" || return 1
}

write_secret_environment_file() {
  local target_file=${1:?target file required}
  local env_name=${2:?environment variable name required}
  local api_key=${3:?API key required}

  [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  is_supported_api_key "$api_key" || return 1
  # Double quotes keep values such as "~" literal when this file is sourced by
  # Bash during checks, and are also accepted by systemd EnvironmentFile=.
  printf '%s="%s"\n' "$env_name" "$api_key" > "$target_file" || return 1
  chmod 600 "$target_file" || return 1
}

read_secret_environment_value() {
  local secret_file=${1:?secret file required}
  local env_name=${2:?environment variable name required}
  local first_line extra_line value prefix secret_fd

  [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  exec {secret_fd}< "$secret_file" || return 1
  IFS= read -r first_line <&"$secret_fd" || {
    exec {secret_fd}<&-
    return 1
  }
  if IFS= read -r extra_line <&"$secret_fd"; then
    exec {secret_fd}<&-
    return 1
  fi
  exec {secret_fd}<&-

  prefix="$env_name="
  [[ "$first_line" == "$prefix"* ]] || return 1
  value=${first_line#"$prefix"}
  if [[ ${#value} -ge 2 && ${value:0:1} == '"' && ${value: -1} == '"' ]]; then
    value=${value:1:${#value}-2}
  elif [[ "$value" == *'"'* ]]; then
    return 1
  fi
  is_supported_api_key "$value" || return 1
  CODEX_RP_SECRET_VALUE=$value
}

write_command_launcher() {
  local target_file=${1:?target file required}
  local setup_script=${2:?setup script required}
  local marker='# Managed by codex-remote-provider-kit'

  if ! {
    printf '#!/usr/bin/env bash\n' \
      && printf '%s\n' "$marker" \
      && printf 'if (($# == 0)); then set -- menu; fi\n' \
      && printf 'exec %q "$@"\n' "$setup_script"
  } > "$target_file"; then
    return 1
  fi
  chmod 755 "$target_file" || return 1
}

install_global_command() {
  local setup_script=${1:?setup script required}
  local command_file=${2:-/usr/local/bin/codex-rp}
  local marker='# Managed by codex-remote-provider-kit'
  local temp_file

  if [[ -L "$command_file" ]] || { [[ -e "$command_file" ]] \
      && [[ ! -f "$command_file" ]]; }; then
    printf '错误：%s 已存在，且不是可安全替换的普通文件\n' \
      "$command_file" >&2
    return 1
  fi
  if [[ -e "$command_file" ]] && ! grep -Fxq "$marker" "$command_file"; then
    printf '错误：%s 已存在，且不由本套件管理\n' "$command_file" >&2
    return 1
  fi
  temp_file=$(mktemp) || return 1
  if ! write_command_launcher "$temp_file" "$setup_script"; then
    rm -f "$temp_file" || true
    return 1
  fi
  if ! install -m 755 "$temp_file" "$command_file"; then
    rm -f "$temp_file" || true
    return 1
  fi
  rm -f "$temp_file" || return 1
}

set_state_variable() {
  local state_file=${1:?state file required}
  local key=${2:?state key required}
  local value=${3-}
  local encoded temp_file

  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
  printf -v encoded '%q' "$value" || return 1
  temp_file=$(mktemp) || return 1
  if ! CODEX_RP_STATE_KEY="$key" CODEX_RP_STATE_ENCODED="$encoded" awk '
    BEGIN {
      key=ENVIRON["CODEX_RP_STATE_KEY"]
      encoded=ENVIRON["CODEX_RP_STATE_ENCODED"]
      wrote=0
    }
    $0 ~ "^" key "=" {
      if (!wrote) print key "=" encoded
      wrote=1
      next
    }
    { print }
    END { if (!wrote) print key "=" encoded }
  ' "$state_file" > "$temp_file"; then
    rm -f "$temp_file" || true
    return 1
  fi
  if ! install -m 600 "$temp_file" "$state_file"; then
    rm -f "$temp_file" || true
    return 1
  fi
  rm -f "$temp_file" || return 1
}

write_third_party_unit() {
  local target_file=${1:?target file required}
  local codex_bin=${2:?Codex executable required}
  local secret_file=${3:?secret file required}
  local provider_id=${4:?provider id required}
  local model=${5:?model required}
  local reasoning=${6:?reasoning effort required}

  cat > "$target_file" <<EOF
# Managed by codex-remote-provider-kit
[Unit]
Description=使用第三方模型供应商的 Codex Remote
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
}

write_official_unit() {
  local target_file=${1:?target file required}
  local codex_bin=${2:?Codex executable required}
  local session_provider_id=${3:?session provider id required}

  [[ "$session_provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1

  cat > "$target_file" <<EOF
# Managed by codex-remote-provider-kit
[Unit]
Description=使用默认/官方模型供应商的 Codex Remote
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
WorkingDirectory=/root
Environment=HOME=/root
ExecStart=$codex_bin remote-control start --json -c model_provider=$session_provider_id
ExecStop=$codex_bin remote-control stop --json
Restart=no

[Install]
WantedBy=multi-user.target
EOF
}

# Rollouts persist this identity, so switching only changes the provider block
# behind it. PROVIDER_ID remains the selected third-party registry record.
session_provider_id() {
  local provider_id=${SESSION_PROVIDER_ID:-${PROVIDER_ID:-}}

  [[ -n "$provider_id" && "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  printf '%s\n' "$provider_id"
}

official_codex_base_url() {
  local base_url=https://chatgpt.com/backend-api/codex

  [[ "$base_url" =~ ^https://[^[:space:]]+$ ]] || return 1
  [[ "$base_url" != *'@'* && "$base_url" != *'?'* && "$base_url" != *'#'* \
      && "$base_url" != *\"* && "$base_url" != *\\* ]] || return 1
  printf '%s\n' "${base_url%/}"
}

remove_managed_provider_block() {
  local config_file=${1:?config file required}
  local provider_id=${2:?provider id required}
  local begin_marker end_marker temp_file

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  begin_marker="# BEGIN codex-remote-provider-kit:$provider_id"
  end_marker="# END codex-remote-provider-kit:$provider_id"
  temp_file=$(mktemp) || return 1
  if ! awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$config_file" > "$temp_file"; then
    rm -f "$temp_file" || true
    return 1
  fi

  if grep -Eq "^[[:space:]]*\[model_providers\.${provider_id//./\\.}\][[:space:]]*$" \
      "$temp_file"; then
    printf '配置已在套件管理区块之外定义 model_providers.%s\n' \
      "$provider_id" >&2
    rm -f "$temp_file"
    return 1
  fi
  if ! install -m 600 "$temp_file" "$config_file"; then
    rm -f "$temp_file" || true
    return 1
  fi
  rm -f "$temp_file" || return 1
}

configure_third_party_session_provider() {
  local config_file=${1:?config file required}
  local provider_id=${2:?provider id required}
  local base_url=${3:?Base URL required}
  local env_name=${4:?environment variable name required}
  local begin_marker end_marker

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [[ "$base_url" =~ ^https?://[^[:space:]]+$ ]] || return 1
  [[ "$base_url" != *\"* && "$base_url" != *\\* ]] || return 1
  remove_managed_provider_block "$config_file" "$provider_id" || return 1
  begin_marker="# BEGIN codex-remote-provider-kit:$provider_id"
  end_marker="# END codex-remote-provider-kit:$provider_id"
  cat >> "$config_file" <<EOF || return 1

$begin_marker
[model_providers.$provider_id]
name = "$provider_id"
base_url = "${base_url%/}"
env_key = "$env_name"
wire_api = "responses"
$end_marker
EOF
}

configure_official_session_provider() {
  local config_file=${1:?config file required}
  local provider_id=${2:?provider id required}
  local base_url begin_marker end_marker

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  base_url=$(official_codex_base_url) || return 1
  remove_managed_provider_block "$config_file" "$provider_id" || return 1
  begin_marker="# BEGIN codex-remote-provider-kit:$provider_id"
  end_marker="# END codex-remote-provider-kit:$provider_id"
  cat >> "$config_file" <<EOF || return 1

$begin_marker
[model_providers.$provider_id]
name = "$provider_id"
base_url = "$base_url"
requires_openai_auth = true
wire_api = "responses"
$end_marker
EOF
}

restore_remote_service_selection() {
  local codex_bin=${1:?Codex executable required}
  local third_party_unit=${2:?third-party unit required}
  local official_unit=${3:?official unit required}
  local third_party_enabled=${4:?third-party enabled state required}
  local third_party_active=${5:?third-party active state required}
  local official_enabled=${6:?official enabled state required}
  local official_active=${7:?official active state required}
  local recovery_failed='no'

  if ! systemctl disable --now "$third_party_unit" >/dev/null 2>&1; then
    printf '自动恢复失败：无法停用 %s\n' "$third_party_unit" >&2
    recovery_failed='yes'
  fi
  if ! systemctl disable --now "$official_unit" >/dev/null 2>&1; then
    printf '自动恢复失败：无法停用 %s\n' "$official_unit" >&2
    recovery_failed='yes'
  fi
  if ! "$codex_bin" remote-control stop --json >/dev/null 2>&1; then
    printf '自动恢复失败：无法停止当前 Codex Remote daemon\n' >&2
    recovery_failed='yes'
  fi

  if [[ "$third_party_enabled" == yes ]]; then
    if ! systemctl enable "$third_party_unit" >/dev/null 2>&1; then
      printf '自动恢复失败：无法重新启用 %s\n' "$third_party_unit" >&2
      recovery_failed='yes'
    fi
  fi
  if [[ "$official_enabled" == yes ]]; then
    if ! systemctl enable "$official_unit" >/dev/null 2>&1; then
      printf '自动恢复失败：无法重新启用 %s\n' "$official_unit" >&2
      recovery_failed='yes'
    fi
  fi
  if [[ "$third_party_active" == yes ]]; then
    if ! systemctl start "$third_party_unit" >/dev/null 2>&1; then
      printf '自动恢复失败：无法重新启动 %s\n' "$third_party_unit" >&2
      recovery_failed='yes'
    fi
  fi
  if [[ "$official_active" == yes ]]; then
    if ! systemctl start "$official_unit" >/dev/null 2>&1; then
      printf '自动恢复失败：无法重新启动 %s\n' "$official_unit" >&2
      recovery_failed='yes'
    fi
  fi
  [[ "$recovery_failed" == no ]]
}

remote_service_mode() {
  local third_party_unit=${1:?third-party unit required}
  local official_unit=${2:?official unit required}
  local third_party_active=no official_active=no
  local third_party_enabled=no official_enabled=no

  systemctl is-active "$third_party_unit" >/dev/null 2>&1 && third_party_active=yes
  systemctl is-active "$official_unit" >/dev/null 2>&1 && official_active=yes
  systemctl is-enabled "$third_party_unit" >/dev/null 2>&1 && third_party_enabled=yes
  systemctl is-enabled "$official_unit" >/dev/null 2>&1 && official_enabled=yes

  if [[ "$third_party_active" == yes && "$official_active" == yes ]] \
      || [[ "$third_party_enabled" == yes && "$official_enabled" == yes ]]; then
    return 1
  elif [[ "$third_party_active" == yes ]]; then
    [[ "$official_enabled" == no ]] || return 1
    printf 'third-party\n'
    return 0
  elif [[ "$official_active" == yes ]]; then
    [[ "$third_party_enabled" == no ]] || return 1
    printf 'official\n'
    return 0
  fi

  if [[ "$third_party_enabled" == yes ]]; then
    printf 'third-party\n'
  elif [[ "$official_enabled" == yes ]]; then
    printf 'official\n'
  else
    printf 'none\n'
  fi
}

set_top_level_string() {
  local config_file=${1:?config file required}
  local key=${2:?key required}
  local value=${3:?value required}
  local temp_file

  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    printf '配置键无效：%s\n' "$key" >&2
    return 1
  }
  [[ "$value" != *$'\n'* && "$value" != *\"* && "$value" != *\\* ]] || {
    printf '配置项 %s 的值包含不支持的字符\n' "$key" >&2
    return 1
  }
  if [[ -e "$config_file" || -L "$config_file" ]]; then
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 1
  else
    install -m 600 /dev/null "$config_file" || return 1
  fi

  temp_file=$(mktemp) || return 1
  if ! awk -v key="$key" -v value="$value" '
    BEGIN { in_top = 1; wrote = 0 }
    in_top && /^[[:space:]]*\[/ {
      if (!wrote) {
        print key " = \"" value "\""
        wrote = 1
      }
      in_top = 0
    }
    in_top && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (!wrote) {
        print key " = \"" value "\""
        wrote = 1
      }
      next
    }
    { print }
    END {
      if (in_top && !wrote) print key " = \"" value "\""
    }
  ' "$config_file" > "$temp_file"; then
    rm -f "$temp_file" || true
    return 1
  fi

  if ! python3 - "$temp_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY
  then
    rm -f "$temp_file" || true
    return 1
  fi

  if ! install -m 600 "$temp_file" "$config_file"; then
    rm -f "$temp_file" || true
    return 1
  fi
  rm -f "$temp_file" || return 1
}

remove_top_level_key() {
  local config_file=${1:?config file required}
  local key=${2:?key required}
  local temp_file

  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  if [[ -e "$config_file" || -L "$config_file" ]]; then
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 1
  else
    return 0
  fi
  temp_file=$(mktemp) || return 1
  if ! awk -v key="$key" '
    BEGIN { in_top = 1 }
    in_top && /^[[:space:]]*\[/ { in_top = 0 }
    in_top && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { next }
    { print }
  ' "$config_file" > "$temp_file"; then
    rm -f "$temp_file" || true
    return 1
  fi

  if ! python3 - "$temp_file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY
  then
    rm -f "$temp_file" || true
    return 1
  fi

  if ! install -m 600 "$temp_file" "$config_file"; then
    rm -f "$temp_file" || true
    return 1
  fi
  rm -f "$temp_file" || return 1
}

set_remote_defaults() {
  local config_file=${1:?config file required}
  local provider_id=${2:?provider id required}
  local model=${3:?model required}
  local reasoning=${4:?reasoning effort required}

  [[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$reasoning" =~ ^(none|minimal|low|medium|high|xhigh)$ ]] || return 1
  set_top_level_string "$config_file" model_provider "$provider_id" || return 1
  set_top_level_string "$config_file" model "$model" || return 1
  set_top_level_string "$config_file" model_reasoning_effort "$reasoning" || return 1
}

restore_remote_defaults() {
  local config_file=${1:?config file required}
  local backup_file=${2:?backup file required}
  local key value

  for key in model_provider model model_reasoning_effort; do
    if ! value=$(python3 - "$backup_file" "$key" <<'PY'
import pathlib, sys, tomllib
path = pathlib.Path(sys.argv[1])
data = tomllib.loads(path.read_text()) if path.is_file() else {}
value = data.get(sys.argv[2])
if isinstance(value, str):
    print(value)
PY
); then
      return 1
    fi
    if [[ -n "$value" ]]; then
      set_top_level_string "$config_file" "$key" "$value" || return 1
    else
      remove_top_level_key "$config_file" "$key" || return 1
    fi
  done
}

restore_official_model_defaults() {
  local config_file=${1:?config file required}
  local backup_file=${2:?backup file required}
  local key value

  for key in model model_reasoning_effort; do
    if ! value=$(python3 - "$backup_file" "$key" <<'PY'
import pathlib, sys, tomllib
path = pathlib.Path(sys.argv[1])
data = tomllib.loads(path.read_text()) if path.is_file() else {}
value = data.get(sys.argv[2])
if isinstance(value, str):
    print(value)
PY
); then
      return 1
    fi
    if [[ -n "$value" ]]; then
      set_top_level_string "$config_file" "$key" "$value" || return 1
    else
      remove_top_level_key "$config_file" "$key" || return 1
    fi
  done
}

set_default_provider() {
  set_top_level_string "${1:?config file required}" model_provider "${2:?provider id required}"
}

remove_default_provider() {
  remove_top_level_key "${1:?config file required}" model_provider
}
