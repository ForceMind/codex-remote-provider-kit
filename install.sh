#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

usage() {
  cat <<'EOF'
Usage: sudo -E ./install.sh --base-url URL --model MODEL [options]

Options:
  --provider-id ID       Provider/profile id (default: inno_flare)
  --env-name NAME        API key environment name (default: INNO_FLARE_API_KEY)
  --codex-home DIR       Codex home (default: $CODEX_HOME or /root/.codex)
  --codex-bin PATH       Codex executable (auto-detected)
  --reasoning EFFORT     Reasoning effort (default: high)
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

provider_id='inno_flare'
env_name='INNO_FLARE_API_KEY'
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
    *) die "unknown argument: $1" ;;
  esac
done

((EUID == 0)) || die 'run as root'
[[ -n "$base_url" && -n "$model" ]] || { usage; die '--base-url and --model are required'; }
[[ "$provider_id" =~ ^[A-Za-z0-9_-]+$ ]] || die 'invalid provider id'
[[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die 'invalid environment name'
[[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || die 'invalid model name'
[[ "$reasoning" =~ ^(none|minimal|low|medium|high|xhigh)$ ]] || die 'invalid reasoning effort'
[[ "$base_url" =~ ^https?://[^[:space:]]+$ ]] || die 'base URL must be HTTP(S) without spaces'
[[ "$base_url" != *\"* && "$base_url" != *\\* ]] || die 'base URL cannot contain quotes or backslashes'
base_url=${base_url%/}

if [[ -z "$codex_bin" ]]; then
  for candidate in /root/.local/bin/codex /usr/local/bin/codex /usr/bin/codex; do
    [[ -x "$candidate" ]] && { codex_bin=$candidate; break; }
  done
fi
[[ -n "$codex_bin" && -x "$codex_bin" ]] || die 'Codex executable not found; pass --codex-bin'
"$codex_bin" remote-control start --help >/dev/null 2>&1 || die 'this Codex version lacks remote-control start'
is_chatgpt_logged_in "$codex_bin" || die 'Codex is not logged in with ChatGPT'

api_key=${!env_name-}
if [[ -z "$api_key" && -t 0 ]]; then
  read -rsp "${env_name}: " api_key
  printf '\n'
fi
[[ -n "$api_key" ]] || die "set $env_name or run interactively"
[[ "$api_key" != *$'\n'* ]] || die 'API key must be one line'
[[ "$api_key" =~ ^[A-Za-z0-9._~+/-]+$ ]] || die 'API key contains unsupported characters'

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
  die "$command_file already exists and is not managed by this kit"
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
  die "config already defines model_providers.$provider_id outside the managed block"
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
Description=Codex Remote with custom model provider
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
print("TOML validation: ok")
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
if [[ "$legacy_enabled" == yes ]]; then systemctl disable codex.service; fi
"$codex_bin" remote-control stop --json >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now codex-remote-provider.service

printf 'Installed provider %s with model %s.\n' "$provider_id" "$model"
printf 'Backup: %s\n' "$backup_dir"
printf 'Background service is enabled for boot.\n'
printf 'Open the panel from any directory: codex-rp\n'
printf 'Run: sudo %s/status.sh --full\n' "$script_dir"
