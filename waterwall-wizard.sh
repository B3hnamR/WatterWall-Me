#!/usr/bin/env bash
set -euo pipefail

APP_NAME="WaterWall"
APP_VERSION="0.2.1"
APP_GITHUB="https://github.com/B3hnamR/WatterWall-Me"
APP_TELEGRAM="@b3hnamrjd"
CURRENT_ROLE=""
USE_WHIPTAIL="0"
DEFAULT_AUTHOR=""
DEFAULT_CONFIG_VERSION="1"
DEFAULT_CORE_MIN_VERSION="1"
DEFAULT_BASE_DIR="${WATERWALL_DIR:-/opt/waterwall}"
MANAGEMENT_BASE_DIR="$DEFAULT_BASE_DIR"
CORE_RELEASE_API_URL="https://api.github.com/repos/radkesvat/WaterWall/releases/latest"
CORE_FALLBACK_ASSET="Waterwall-linux-gcc-x64-old-cpu.zip"
CORE_DOWNLOAD_URL=""
CORE_BIN_NAME="Waterwall"
CORE_BIN_PATH=""
SUDO=""

if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

# Usage:
#   bash waterwall-wizard.sh
# Generates core.json and configs/*.json in your target directory.
# Run it in the same folder as WaterWall (or point to that folder).
# For a nicer UI, install `whiptail` (optional).

# ---------- UI helpers ----------

has_whiptail() {
  [[ "$USE_WHIPTAIL" == "1" ]] && command -v whiptail >/dev/null 2>&1
}

ui_msg() {
  local msg="$1"
  echo ""
  echo "$msg"
  echo ""
  if [[ -t 0 ]]; then
    read -r -p "Enter to continue..." _
  fi
}

ui_confirm() {
  local msg="$1"
  local def="${2:-N}"
  local ans
  local prompt="[y/N]"
  if [[ "${def,,}" == "y" ]]; then
    prompt="[Y/n]"
  fi
  read -r -p "$msg $prompt: " ans
  if [[ -z "${ans:-}" ]]; then
    ans="$def"
  fi
  case "${ans,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

ui_input() {
  local prompt="$1"
  local defval="${2:-}"
  local out
  printf '\n' >&2
  printf '%s\n' "$prompt" >&2
  if [[ -n "$defval" ]]; then
    printf 'Default: %s\n' "$defval" >&2
  else
    printf 'Default: (empty)\n' >&2
  fi
  read -r -p "Enter value (leave empty for default): " out
  if [[ -z "${out:-}" ]]; then
    printf '%s' "$defval"
  else
    printf '%s' "$out"
  fi
}

ui_menu() {
  local title="$1"
  local prompt="$2"
  local default_tag="$3"
  shift 3
  local options=("$@")
  local tags=()
  local labels=()
  local opt
  for opt in "${options[@]}"; do
    tags+=("${opt%%|*}")
    labels+=("${opt#*|}")
  done
  local default_index=""
  if [[ -n "$default_tag" ]]; then
    local idx=0
    for opt in "${tags[@]}"; do
      idx=$((idx+1))
      if [[ "$opt" == "$default_tag" ]]; then
        default_index="$idx"
        break
      fi
    done
    if [[ -z "$default_index" ]]; then
      default_index="1"
    fi
  fi
  while true; do
    printf '\n' >&2
    printf '%s\n' "$title" >&2
    printf '%s\n' "$prompt" >&2
    local i=1
    for opt in "${labels[@]}"; do
      printf '  %s) %s\n' "$i" "$opt" >&2
      i=$((i+1))
    done
    local prompt_line="Select [1-${#tags[@]}]"
    if [[ -n "$default_index" ]]; then
      prompt_line="$prompt_line (default $default_index)"
    fi
    local sel=""
    read -r -p "$prompt_line: " sel
    if [[ -z "${sel:-}" && -n "$default_index" ]]; then
      sel="$default_index"
    fi
    if [[ -n "${sel:-}" ]] && [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#tags[@]} )); then
      printf '%s' "${tags[$((sel-1))]}"
      return 0
    fi
    printf '%s\n' "Invalid selection." >&2
  done
}

# ---------- Helpers ----------

die() {
  ui_msg "Error: $1"
  exit 1
}

print_header() {
  clear
  echo "========================================"
  echo " Tunnel Wizard"
  echo " Project: WaterWall"
  echo " Version: v$APP_VERSION"
  echo " Github: $APP_GITHUB"
  echo " Telegram: $APP_TELEGRAM"
  echo "========================================"
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//"/\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  printf '%s' "$s"
}

sanitize_name() {
  local s="$1"
  s=${s// /_}
  s=${s//[^a-zA-Z0-9._-]/_}
  printf '%s' "$s"
}

is_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

prompt_port() {
  local label="$1"
  local defval="$2"
  local p
  while true; do
    p=$(ui_input "$label" "$defval") || return 1
    if is_port "$p"; then
      printf '%s' "$p"
      return 0
    fi
    ui_msg "Invalid port: $p"
  done
}

prompt_port_range() {
  local min_label="$1"
  local max_label="$2"
  local def_min="$3"
  local def_max="$4"
  local pmin pmax
  while true; do
    pmin=$(prompt_port "$min_label" "$def_min") || return 1
    pmax=$(prompt_port "$max_label" "$def_max") || return 1
    if (( pmin <= pmax )); then
      printf '%s %s' "$pmin" "$pmax"
      return 0
    fi
    ui_msg "Range invalid: min must be <= max"
  done
}

csv_to_json_array() {
  local csv="$1"
  local out="["
  local first=true
  IFS=',' read -ra parts <<< "$csv"
  for part in "${parts[@]}"; do
    part=$(echo "$part" | sed -e 's/^ *//' -e 's/ *$//')
    if [[ -z "$part" ]]; then
      continue
    fi
    if $first; then
      out+="\"$(json_escape "$part")\""
      first=false
    else
      out+=", \"$(json_escape "$part")\""
    fi
  done
  out+="]"
  printf '%s' "$out"
}

bool_to_json() {
  if [[ "$1" == "true" ]]; then
    printf '%s' "true"
  else
    printf '%s' "false"
  fi
}

backup_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    local ts
    ts=$(date +"%Y%m%d-%H%M%S")
    cp -f "$path" "${path}.bak-${ts}"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  backup_file "$path"
  printf '%s' "$content" > "$path"
}

ensure_dir() {
  local d="$1"
  $SUDO mkdir -p "$d"
}

get_cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN
  else
    echo "1"
  fi
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi
  if [[ -n "$SUDO" ]]; then
    return 0
  fi
  ui_msg "This action requires root or sudo."
  return 1
}

install_pkg() {
  local pkg="$1"
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -y
    $SUDO apt-get install -y "$pkg"
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y "$pkg"
    return 0
  fi
  if command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y "$pkg"
    return 0
  fi
  if command -v apk >/dev/null 2>&1; then
    $SUDO apk add --no-cache "$pkg"
    return 0
  fi
  if command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -Sy --noconfirm "$pkg"
    return 0
  fi
  if command -v zypper >/dev/null 2>&1; then
    $SUDO zypper --non-interactive install "$pkg"
    return 0
  fi
  return 1
}

download_file() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dest" "$url"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
    return 0
  fi
  return 1
}

ensure_unzip() {
  if command -v unzip >/dev/null 2>&1; then
    return 0
  fi
  if ! need_root; then
    return 1
  fi
  install_pkg unzip
}

ensure_layout() {
  ensure_base_dir || return 1
  ensure_dir "$MANAGEMENT_BASE_DIR"
  ensure_dir "$MANAGEMENT_BASE_DIR/configs"
  ensure_dir "$MANAGEMENT_BASE_DIR/logs"
  ensure_dir "$MANAGEMENT_BASE_DIR/libs"
}

find_core_bin() {
  local bin=""
  if [[ -x "$MANAGEMENT_BASE_DIR/$CORE_BIN_NAME" ]]; then
    bin="$MANAGEMENT_BASE_DIR/$CORE_BIN_NAME"
  elif [[ -x "$MANAGEMENT_BASE_DIR/${CORE_BIN_NAME,,}" ]]; then
    bin="$MANAGEMENT_BASE_DIR/${CORE_BIN_NAME,,}"
  elif command -v waterwall >/dev/null 2>&1; then
    bin=$(command -v waterwall)
  elif command -v Waterwall >/dev/null 2>&1; then
    bin=$(command -v Waterwall)
  fi
  if [[ -n "$bin" ]]; then
    CORE_BIN_PATH="$bin"
    return 0
  fi
  return 1
}

get_arch() {
  uname -m 2>/dev/null || echo "unknown"
}

cpu_has_avx512() {
  if [[ -r /proc/cpuinfo ]]; then
    grep -qi "avx512" /proc/cpuinfo
    return $?
  fi
  return 1
}

select_asset_candidates() {
  local arch
  arch=$(get_arch)
  case "$arch" in
    x86_64|amd64)
      if cpu_has_avx512; then
        echo "Waterwall-linux-clang-avx512f-x64.zip"
      fi
      echo "Waterwall-linux-clang-x64.zip"
      echo "Waterwall-linux-gcc-x64.zip"
      echo "Waterwall-linux-gcc-x64-old-cpu.zip"
      ;;
    aarch64|arm64)
      echo "Waterwall-linux-gcc-arm64.zip"
      echo "Waterwall-linux-gcc-arm64-old-cpu.zip"
      ;;
    armv7l|armv6l)
      echo "Waterwall-linux-gcc-arm.zip"
      echo "Waterwall-linux-gcc-arm-old-cpu.zip"
      ;;
    *)
      echo "$CORE_FALLBACK_ASSET"
      ;;
  esac
}

fetch_release_json() {
  local tmp
  tmp=$(mktemp)
  if ! download_file "$CORE_RELEASE_API_URL" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
  return 0
}

extract_asset_url() {
  local json="$1"
  local name="$2"
  if command -v python >/dev/null 2>&1; then
    printf '%s' "$json" | python - "$name" <<'PY'
import json, sys
name = sys.argv[1]
try:
    data = json.load(sys.stdin)
    for a in data.get("assets", []):
        if a.get("name") == name:
            print(a.get("browser_download_url", ""))
            break
except Exception:
    pass
PY
    return 0
  fi
  local flat marker after url
  flat=$(echo "$json" | tr -d '\n')
  marker="\"name\":\"$name\""
  if [[ "$flat" != *$marker* ]]; then
    return 0
  fi
  after="${flat#*$marker}"
  after="${after#*\"browser_download_url\":\"}"
  url="${after%%\"*}"
  printf '%s' "$url"
}

resolve_core_download_url() {
  local json
  json=$(fetch_release_json) || return 1
  local cand url
  while read -r cand; do
    [[ -z "$cand" ]] && continue
    url=$(extract_asset_url "$json" "$cand")
    if [[ -n "$url" ]]; then
      CORE_DOWNLOAD_URL="$url"
      return 0
    fi
  done < <(select_asset_candidates)
  return 1
}

build_candidate_urls() {
  if resolve_core_download_url; then
    echo "$CORE_DOWNLOAD_URL"
  fi
  local cand
  while read -r cand; do
    [[ -z "$cand" ]] && continue
    echo "https://github.com/radkesvat/WaterWall/releases/latest/download/$cand"
  done < <(select_asset_candidates)
  echo "https://github.com/radkesvat/WaterWall/releases/latest/download/$CORE_FALLBACK_ASSET"
}

download_core_zip() {
  local tmp="$1"
  local url
  while read -r url; do
    [[ -z "$url" ]] && continue
    if download_file "$url" "$tmp"; then
      CORE_DOWNLOAD_URL="$url"
      return 0
    fi
  done < <(build_candidate_urls)
  return 1
}

install_core() {
  if ! need_root; then
    return 1
  fi
  ensure_layout || return 1
  if ! ensure_unzip; then
    ui_msg "Missing unzip. Install it and retry."
    return 1
  fi
  local tmp="/tmp/waterwall-core.zip"
  if ! download_core_zip "$tmp"; then
    ui_msg "Download failed. Check network or URL."
    return 1
  fi
  $SUDO unzip -o "$tmp" -d "$MANAGEMENT_BASE_DIR" >/dev/null
  rm -f "$tmp"
  local bin
  bin=$(find "$MANAGEMENT_BASE_DIR" -maxdepth 2 -type f -iname "waterwall" | head -n1 || true)
  if [[ -z "$bin" ]]; then
    ui_msg "WaterWall binary not found after extraction."
    return 1
  fi
  $SUDO chmod +x "$bin"
  if [[ "$bin" != "$MANAGEMENT_BASE_DIR/$CORE_BIN_NAME" ]]; then
    $SUDO mv -f "$bin" "$MANAGEMENT_BASE_DIR/$CORE_BIN_NAME"
    bin="$MANAGEMENT_BASE_DIR/$CORE_BIN_NAME"
  fi
  $SUDO ln -sf "$bin" /usr/local/bin/waterwall >/dev/null 2>&1 || true
  CORE_BIN_PATH="$bin"
  return 0
}

ensure_core_installed() {
  local force="${1:-0}"
  if [[ "$force" != "1" ]] && find_core_bin; then
    return 0
  fi
  echo ""
  echo "Installing WaterWall core..."
  install_core
}

# ---------- Core.json ----------

generate_core_json() {
  local target_dir="$1"
  shift
  local config_paths=("$@")

  local use_defaults
  if ui_confirm "Use default core.json settings? (Recommended)" "Y"; then
    use_defaults="yes"
  else
    use_defaults="no"
  fi

  local log_path="logs/"
  local workers="0"
  local ram_profile="client"
  local mtu="1500"
  local libs_path="libs/"

  if [[ "$use_defaults" == "no" ]]; then
    log_path=$(ui_input "Log path" "$log_path") || return 1

    local workers_in
    workers_in=$(ui_input "Workers (0 = auto)" "$workers") || return 1
    if [[ "$workers_in" =~ ^[0-9]+$ ]] && (( workers_in >= 0 )); then
      workers="$workers_in"
    fi

    local rp
    rp=$(ui_menu "$APP_NAME" "Select RAM profile" "client" \
      "client|Client (default)" \
      "server|Server" \
      "client-larger|Client (larger)" \
      "minimal|Minimal/UltraLow") || return 1
    ram_profile="$rp"

    mtu=$(ui_input "MTU" "$mtu") || return 1
    libs_path=$(ui_input "Libs path" "$libs_path") || return 1
  fi

  local configs_json=""
  local first=true
  local cp
  for cp in "${config_paths[@]}"; do
    local esc
    esc=$(json_escape "$cp")
    if $first; then
      configs_json="    \"$esc\""
      first=false
    else
      configs_json="$configs_json,\n    \"$esc\""
    fi
  done

  local core_json
  core_json=$(cat <<EOF
{
  "log": {
    "path": "$(json_escape "$log_path")",
    "internal": {"loglevel": "INFO", "file": "internal.log", "console": true},
    "core": {"loglevel": "INFO", "file": "core.log", "console": true},
    "network": {"loglevel": "WARN", "file": "network.log", "console": true},
    "dns": {"loglevel": "ERROR", "file": "dns.log", "console": true}
  },
  "misc": {
    "workers": $workers,
    "ram-profile": "$(json_escape "$ram_profile")",
    "mtu": $mtu,
    "libs-path": "$(json_escape "$libs_path")"
  },
  "configs": [
$configs_json
  ]
}
EOF
)

  ensure_dir "$target_dir"
  write_file "$target_dir/core.json" "$core_json"
}

# ---------- Templates ----------

select_role() {
  local def="${1:-iran}"
  ui_menu "$APP_NAME" "Where is this server?" "$def" \
    "iran|Iran" \
    "abroad|Kharej"
}

prompt_common_paths() {
  local dir
  dir=$(ui_input "Target directory for core.json/configs" "$MANAGEMENT_BASE_DIR") || return 1
  printf '%s' "$dir"
}

ensure_role() {
  local def="${CURRENT_ROLE:-iran}"
  CURRENT_ROLE=$(select_role "$def") || return 1
  return 0
}

ensure_base_dir() {
  if [[ -z "$MANAGEMENT_BASE_DIR" ]]; then
    MANAGEMENT_BASE_DIR="$DEFAULT_BASE_DIR"
  fi
  return 0
}

get_target_dir() {
  ensure_base_dir || return 1
  printf '%s' "$MANAGEMENT_BASE_DIR"
  return 0
}

select_config_file() {
  local config_dir="$1"
  local files=()
  local f
  for f in "$config_dir"/*.json; do
    [[ -f "$f" ]] && files+=("$f")
  done
  if [[ ${#files[@]} -eq 0 ]]; then
    ui_msg "No config files found in $config_dir"
    return 1
  fi

  if has_whiptail; then
    local options=()
    local fbase
    for f in "${files[@]}"; do
      fbase=$(basename "$f")
      options+=("$f" "$fbase")
    done
    local def="${files[0]}"
    ui_menu "$APP_NAME" "Select a config" "$def" "${options[@]}"
  else
    printf '\n' >&2
    printf 'Configs in %s:\n' "$config_dir" >&2
    local i=1
    for f in "${files[@]}"; do
      printf '  %s) %s\n' "$i" "$(basename "$f")" >&2
      i=$((i+1))
    done
    local sel
    read -r -p "Select [1-${#files[@]}] (default 1): " sel
    if [[ -z "${sel:-}" ]]; then
      sel="1"
    fi
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#files[@]} )); then
      printf '%s\n' "Invalid selection." >&2
      return 1
    fi
    printf '%s' "${files[$((sel-1))]}"
  fi
}

open_editor() {
  local file="$1"
  if [[ -n "${EDITOR:-}" ]]; then
    "$EDITOR" "$file"
    return
  fi
  if command -v nano >/dev/null 2>&1; then
    nano "$file"
    return
  fi
  if command -v vi >/dev/null 2>&1; then
    vi "$file"
    return
  fi
  ui_msg "No editor found. Set \$EDITOR or install nano/vi."
}

show_active_configs() {
  local base_dir="$1"
  local core_file="$base_dir/core.json"
  if [[ ! -f "$core_file" ]]; then
    ui_msg "core.json not found in $base_dir"
    return
  fi
  if command -v python >/dev/null 2>&1; then
    local out
    out=$(python - <<PY
import json, sys
try:
    with open(r"$core_file", "r", encoding="utf-8") as f:
        data = json.load(f)
    cfgs = data.get("configs", [])
    if not cfgs:
        print("No configs in core.json")
    else:
        for c in cfgs:
            print(c)
except Exception as e:
    print("Failed to parse core.json:", e)
PY
)
    ui_msg "Active configs (from core.json):\n$out"
    return
  fi
  if command -v jq >/dev/null 2>&1; then
    local out
    out=$(jq -r '.configs[]?' "$core_file")
    if [[ -z "$out" ]]; then
      out="No configs in core.json"
    fi
    ui_msg "Active configs (from core.json):\n$out"
    return
  fi
  ui_msg "Install python or jq to parse core.json.\nFile: $core_file"
}

tunnel_management_menu() {
  local choice
  choice=$(ui_menu "$APP_NAME" "Tunnel management" "new" \
    "new|Create new config" \
    "list|List existing configs" \
    "active|Show active configs (core.json)" \
    "view|View a config" \
    "edit|Edit a config" \
    "core|View core.json" \
    "dir|Set target directory" \
    "role|Change server location (Iran/Kharej)" \
    "back|Back to main menu") || return 0

  case "$choice" in
    new)
      run_wizard || true
      ;;
    list)
      ensure_base_dir || return 0
      local config_dir="$MANAGEMENT_BASE_DIR/configs"
      ensure_dir "$config_dir"
      local files
      files=$(ls -1 "$config_dir"/*.json 2>/dev/null | xargs -n1 basename 2>/dev/null || true)
      if [[ -z "$files" ]]; then
        ui_msg "No configs found in $config_dir"
      else
        ui_msg "Configs in $config_dir:\n$files"
      fi
      ;;
    active)
      ensure_base_dir || return 0
      show_active_configs "$MANAGEMENT_BASE_DIR"
      ;;
    view)
      ensure_base_dir || return 0
      local config_dir="$MANAGEMENT_BASE_DIR/configs"
      ensure_dir "$config_dir"
      local sel
      sel=$(select_config_file "$config_dir") || true
      if [[ -n "${sel:-}" ]]; then
        ui_msg "File: $sel\n\n$(cat "$sel")"
      fi
      ;;
    edit)
      ensure_base_dir || return 0
      local config_dir="$MANAGEMENT_BASE_DIR/configs"
      ensure_dir "$config_dir"
      local sel
      sel=$(select_config_file "$config_dir") || true
      if [[ -n "${sel:-}" ]]; then
        open_editor "$sel"
      fi
      ;;
    core)
      ensure_base_dir || return 0
      local core_file="$MANAGEMENT_BASE_DIR/core.json"
      if [[ -f "$core_file" ]]; then
        ui_msg "File: $core_file\n\n$(cat "$core_file")"
      else
        ui_msg "core.json not found in $MANAGEMENT_BASE_DIR"
      fi
      ;;
    dir)
      MANAGEMENT_BASE_DIR=$(prompt_common_paths) || true
      ;;
    role)
      CURRENT_ROLE=""
      ensure_role || true
      ;;
    back)
      return 0
      ;;
  esac
}

# Template: TCP Port Forward

generate_port_forward_iran() {
  local cfg_name="$1"
  local author="$2"
  local cfg_ver="$3"
  local core_min="$4"
  local listen_addr="$5"
  local listen_port="$6"
  local remote_addr="$7"
  local remote_port="$8"
  local nodelay="$9"

  cat <<EOF
{
  "name": "$(json_escape "$cfg_name")",
  "author": "$(json_escape "$author")",
  "config-version": $cfg_ver,
  "core-minimum-version": $core_min,
  "nodes": [
    {
      "name": "in_listener",
      "type": "TcpListener",
      "settings": {
        "address": "$(json_escape "$listen_addr")",
        "port": $listen_port,
        "nodelay": $nodelay
      },
      "next": "out_connector"
    },
    {
      "name": "out_connector",
      "type": "TcpConnector",
      "settings": {
        "address": "$(json_escape "$remote_addr")",
        "port": $remote_port,
        "nodelay": $nodelay
      }
    }
  ]
}
EOF
}

generate_port_forward_abroad() {
  local cfg_name="$1"
  local author="$2"
  local cfg_ver="$3"
  local core_min="$4"
  local listen_addr="$5"
  local listen_port="$6"
  local backend_addr="$7"
  local backend_port="$8"
  local nodelay="$9"

  cat <<EOF
{
  "name": "$(json_escape "$cfg_name")",
  "author": "$(json_escape "$author")",
  "config-version": $cfg_ver,
  "core-minimum-version": $core_min,
  "nodes": [
    {
      "name": "in_listener",
      "type": "TcpListener",
      "settings": {
        "address": "$(json_escape "$listen_addr")",
        "port": $listen_port,
        "nodelay": $nodelay
      },
      "next": "backend_connector"
    },
    {
      "name": "backend_connector",
      "type": "TcpConnector",
      "settings": {
        "address": "$(json_escape "$backend_addr")",
        "port": $backend_port,
        "nodelay": $nodelay
      }
    }
  ]
}
EOF
}

# Template: TLS Tunnel (OpenSSL Client/Server)

generate_tls_iran() {
  local cfg_name="$1"
  local author="$2"
  local cfg_ver="$3"
  local core_min="$4"
  local listen_addr="$5"
  local listen_port="$6"
  local abroad_addr="$7"
  local abroad_port="$8"
  local sni="$9"
  local verify="${10}"
  local alpn="${11}"

  cat <<EOF
{
  "name": "$(json_escape "$cfg_name")",
  "author": "$(json_escape "$author")",
  "config-version": $cfg_ver,
  "core-minimum-version": $core_min,
  "nodes": [
    {
      "name": "in_listener",
      "type": "TcpListener",
      "settings": {
        "address": "$(json_escape "$listen_addr")",
        "port": $listen_port,
        "nodelay": true
      },
      "next": "tls_client"
    },
    {
      "name": "tls_client",
      "type": "OpenSSLClient",
      "settings": {
        "sni": "$(json_escape "$sni")",
        "verify": $verify,
        "alpn": "$(json_escape "$alpn")"
      },
      "next": "out_connector"
    },
    {
      "name": "out_connector",
      "type": "TcpConnector",
      "settings": {
        "address": "$(json_escape "$abroad_addr")",
        "port": $abroad_port,
        "nodelay": true
      }
    }
  ]
}
EOF
}

generate_tls_abroad() {
  local cfg_name="$1"
  local author="$2"
  local cfg_ver="$3"
  local core_min="$4"
  local listen_addr="$5"
  local listen_port="$6"
  local cert_file="$7"
  local key_file="$8"
  local backend_addr="$9"
  local backend_port="${10}"
  local alpns="${11}"

  cat <<EOF
{
  "name": "$(json_escape "$cfg_name")",
  "author": "$(json_escape "$author")",
  "config-version": $cfg_ver,
  "core-minimum-version": $core_min,
  "nodes": [
    {
      "name": "in_listener",
      "type": "TcpListener",
      "settings": {
        "address": "$(json_escape "$listen_addr")",
        "port": $listen_port,
        "nodelay": true
      },
      "next": "tls_server"
    },
    {
      "name": "tls_server",
      "type": "OpenSSLServer",
      "settings": {
        "cert-file": "$(json_escape "$cert_file")",
        "key-file": "$(json_escape "$key_file")",
        "alpns": $alpns
      },
      "next": "backend_connector"
    },
    {
      "name": "backend_connector",
      "type": "TcpConnector",
      "settings": {
        "address": "$(json_escape "$backend_addr")",
        "port": $backend_port,
        "nodelay": true
      }
    }
  ]
}
EOF
}

# Template: Reality Direct (multiport)

generate_reality_iran() {
  local cfg_name="$1"
  local author="$2"
  local cfg_ver="$3"
  local core_min="$4"
  local listen_addr="$5"
  local pmin="$6"
  local pmax="$7"
  local abroad_addr="$8"
  local abroad_port="$9"
  local sni="${10}"
  local password="${11}"

  cat <<EOF
{
  "name": "$(json_escape "$cfg_name")",
  "author": "$(json_escape "$author")",
  "config-version": $cfg_ver,
  "core-minimum-version": $core_min,
  "nodes": [
    {
      "name": "in_listener",
      "type": "TcpListener",
      "settings": {
        "address": "$(json_escape "$listen_addr")",
        "port": [$pmin, $pmax],
        "nodelay": true
      },
      "next": "header_client"
    },
    {
      "name": "header_client",
      "type": "HeaderClient",
      "settings": {
        "data": "src_context->port"
      },
      "next": "reality_client"
    },
    {
      "name": "reality_client",
      "type": "RealityClient",
      "settings": {
        "sni": "$(json_escape "$sni")",
        "password": "$(json_escape "$password")"
      },
      "next": "out_connector"
    },
    {
      "name": "out_connector",
      "type": "TcpConnector",
      "settings": {
        "address": "$(json_escape "$abroad_addr")",
        "port": $abroad_port,
        "nodelay": true
      }
    }
  ]
}
EOF
}

generate_reality_abroad() {
  local cfg_name="$1"
  local author="$2"
  local cfg_ver="$3"
  local core_min="$4"
  local listen_addr="$5"
  local listen_port="$6"
  local sni_dest="$7"
  local password="$8"

  cat <<EOF
{
  "name": "$(json_escape "$cfg_name")",
  "author": "$(json_escape "$author")",
  "config-version": $cfg_ver,
  "core-minimum-version": $core_min,
  "nodes": [
    {
      "name": "in_listener",
      "type": "TcpListener",
      "settings": {
        "address": "$(json_escape "$listen_addr")",
        "port": $listen_port,
        "nodelay": true
      },
      "next": "reality_server"
    },
    {
      "name": "reality_server",
      "type": "RealityServer",
      "settings": {
        "destination": "reality_dest_node",
        "password": "$(json_escape "$password")"
      },
      "next": "header_server"
    },
    {
      "name": "header_server",
      "type": "HeaderServer",
      "settings": {
        "override": "dest_context->port"
      },
      "next": "backend_connector"
    },
    {
      "name": "backend_connector",
      "type": "TcpConnector",
      "settings": {
        "address": "127.0.0.1",
        "port": "dest_context->port",
        "nodelay": true
      }
    },
    {
      "name": "reality_dest_node",
      "type": "TcpConnector",
      "settings": {
        "address": "$(json_escape "$sni_dest")",
        "port": 443,
        "nodelay": true
      }
    }
  ]
}
EOF
}

# ---------- Wizard ----------

run_wizard() {
  ensure_layout || return 1
  local target_dir
  target_dir=$(get_target_dir) || return 1
  local config_dir="$target_dir/configs"
  ensure_dir "$config_dir"

  ensure_role || return 1
  local role="$CURRENT_ROLE"

  local template
  template=$(ui_menu "$APP_NAME" "Choose a config model" "port_forward" \
    "port_forward|TCP Port Forward (TcpListener -> TcpConnector)" \
    "tls_tunnel|TLS Tunnel (OpenSSL Client/Server)" \
    "reality_direct|Reality Direct (multiport)" \
    "back|Back") || return 1

  if [[ "$template" == "back" ]]; then
    return 0
  fi

  local cfg_paths=()

  case "$template" in
    port_forward)
      local base_name
      base_name=$(ui_input "Config name (base)" "tcp_forward") || return 1
      base_name=$(sanitize_name "$base_name")
      local author
      author=$(ui_input "Author (optional)" "$DEFAULT_AUTHOR") || return 1
      local cfg_ver="$DEFAULT_CONFIG_VERSION"
      local core_min="$DEFAULT_CORE_MIN_VERSION"

      local listen_addr
      listen_addr=$(ui_input "Listener address (usually 0.0.0.0)" "0.0.0.0") || return 1

      local nodelay="true"
      if ! ui_confirm "Enable TCP_NODELAY?" "Y"; then
        nodelay="false"
      fi

      if [[ "$role" == "iran" ]]; then
        local listen_port
        listen_port=$(prompt_port "Iran inbound port (example: 443)" "443") || return 1
        local remote_addr
        remote_addr=$(ui_input "Kharej server IP/domain (enter abroad server IP here)" "1.1.1.1") || return 1
        local remote_port
        remote_port=$(prompt_port "Kharej inbound port" "443") || return 1

        local cfg_name="${base_name}_iran"
        local cfg_file="$config_dir/${cfg_name}.json"
        local cfg_json
        cfg_json=$(generate_port_forward_iran "$cfg_name" "$author" "$cfg_ver" "$core_min" "$listen_addr" "$listen_port" "$remote_addr" "$remote_port" "$nodelay")
        write_file "$cfg_file" "$cfg_json"
        cfg_paths+=("configs/${cfg_name}.json")
      fi

      if [[ "$role" == "abroad" ]]; then
        local listen_port
        listen_port=$(prompt_port "Kharej inbound port (example: 443)" "443") || return 1
        local backend_addr
        backend_addr=$(ui_input "Local service address on abroad server (V2Ray)" "127.0.0.1") || return 1
        local backend_port
        backend_port=$(prompt_port "Local service port on abroad server (V2Ray)" "1080") || return 1

        local cfg_name="${base_name}_abroad"
        local cfg_file="$config_dir/${cfg_name}.json"
        local cfg_json
        cfg_json=$(generate_port_forward_abroad "$cfg_name" "$author" "$cfg_ver" "$core_min" "$listen_addr" "$listen_port" "$backend_addr" "$backend_port" "$nodelay")
        write_file "$cfg_file" "$cfg_json"
        cfg_paths+=("configs/${cfg_name}.json")
      fi
      ;;

    tls_tunnel)
      local base_name
      base_name=$(ui_input "Config name (base)" "tls_tunnel") || return 1
      base_name=$(sanitize_name "$base_name")
      local author
      author=$(ui_input "Author (optional)" "$DEFAULT_AUTHOR") || return 1
      local cfg_ver="$DEFAULT_CONFIG_VERSION"
      local core_min="$DEFAULT_CORE_MIN_VERSION"

      if [[ "$role" == "iran" ]]; then
        local listen_addr listen_port abroad_addr abroad_port sni verify alpn
        listen_addr=$(ui_input "Iran listener address (usually 0.0.0.0)" "0.0.0.0") || return 1
        listen_port=$(prompt_port "Iran inbound port (example: 2083)" "2083") || return 1
        abroad_addr=$(ui_input "Kharej server IP/domain (enter abroad server IP here)" "1.1.1.1") || return 1
        abroad_port=$(prompt_port "Kharej TLS port" "443") || return 1
        sni=$(ui_input "SNI (domain), e.g. mydomain.ir" "mydomain.ir") || return 1
        verify="true"
        if ! ui_confirm "Verify TLS certificate?" "Y"; then
          verify="false"
        fi
        alpn=$(ui_input "ALPN (client), e.g. http/1.1" "http/1.1") || return 1

        local cfg_name="${base_name}_iran"
        local cfg_file="$config_dir/${cfg_name}.json"
        local cfg_json
        cfg_json=$(generate_tls_iran "$cfg_name" "$author" "$cfg_ver" "$core_min" "$listen_addr" "$listen_port" "$abroad_addr" "$abroad_port" "$sni" "$verify" "$alpn")
        write_file "$cfg_file" "$cfg_json"
        cfg_paths+=("configs/${cfg_name}.json")
      fi

      if [[ "$role" == "abroad" ]]; then
        local listen_addr listen_port cert_file key_file backend_addr backend_port alpns_csv alpns_json
        listen_addr=$(ui_input "Kharej listener address (usually 0.0.0.0)" "0.0.0.0") || return 1
        listen_port=$(prompt_port "Kharej TLS inbound port (example: 443)" "443") || return 1
        cert_file=$(ui_input "TLS cert path (e.g. fullchain.pem)" "fullchain.pem") || return 1
        key_file=$(ui_input "TLS key path (e.g. privkey.pem)" "privkey.pem") || return 1
        backend_addr=$(ui_input "Local service address on abroad server (V2Ray)" "127.0.0.1") || return 1
        backend_port=$(prompt_port "Local service port on abroad server (V2Ray)" "2083") || return 1
        alpns_csv=$(ui_input "ALPNs (comma-separated)" "h2,http/1.1") || return 1
        alpns_json=$(csv_to_json_array "$alpns_csv")

        local cfg_name="${base_name}_abroad"
        local cfg_file="$config_dir/${cfg_name}.json"
        local cfg_json
        cfg_json=$(generate_tls_abroad "$cfg_name" "$author" "$cfg_ver" "$core_min" "$listen_addr" "$listen_port" "$cert_file" "$key_file" "$backend_addr" "$backend_port" "$alpns_json")
        write_file "$cfg_file" "$cfg_json"
        cfg_paths+=("configs/${cfg_name}.json")
      fi
      ;;

    reality_direct)
      local base_name
      base_name=$(ui_input "Config name (base)" "reality_direct") || return 1
      base_name=$(sanitize_name "$base_name")
      local author
      author=$(ui_input "Author (optional)" "$DEFAULT_AUTHOR") || return 1
      local cfg_ver="$DEFAULT_CONFIG_VERSION"
      local core_min="$DEFAULT_CORE_MIN_VERSION"

      if [[ "$role" == "iran" ]]; then
        local listen_addr pmin pmax abroad_addr abroad_port sni password
        listen_addr=$(ui_input "Iran listener address (usually 0.0.0.0)" "0.0.0.0") || return 1
        read -r pmin pmax < <(prompt_port_range "Port range MIN" "Port range MAX" "443" "65535") || return 1
        abroad_addr=$(ui_input "Kharej server IP/domain (enter abroad server IP here)" "1.1.1.1") || return 1
        abroad_port=$(prompt_port "Kharej Reality port" "443") || return 1
        sni=$(ui_input "SNI (domain)" "i.stack.imgur.com") || return 1
        password=$(ui_input "Reality password" "passwd") || return 1

        local cfg_name="${base_name}_iran"
        local cfg_file="$config_dir/${cfg_name}.json"
        local cfg_json
        cfg_json=$(generate_reality_iran "$cfg_name" "$author" "$cfg_ver" "$core_min" "$listen_addr" "$pmin" "$pmax" "$abroad_addr" "$abroad_port" "$sni" "$password")
        write_file "$cfg_file" "$cfg_json"
        cfg_paths+=("configs/${cfg_name}.json")
      fi

      if [[ "$role" == "abroad" ]]; then
        local listen_addr listen_port sni password
        listen_addr=$(ui_input "Kharej listener address (usually 0.0.0.0)" "0.0.0.0") || return 1
        listen_port=$(prompt_port "Kharej Reality inbound port (example: 443)" "443") || return 1
        sni=$(ui_input "SNI destination domain" "i.stack.imgur.com") || return 1
        password=$(ui_input "Reality password" "passwd") || return 1

        local cfg_name="${base_name}_abroad"
        local cfg_file="$config_dir/${cfg_name}.json"
        local cfg_json
        cfg_json=$(generate_reality_abroad "$cfg_name" "$author" "$cfg_ver" "$core_min" "$listen_addr" "$listen_port" "$sni" "$password")
        write_file "$cfg_file" "$cfg_json"
        cfg_paths+=("configs/${cfg_name}.json")
      fi
      ;;

    *)
      return 1
      ;;
  esac

  if [[ ${#cfg_paths[@]} -gt 0 ]]; then
    generate_core_json "$target_dir" "${cfg_paths[@]}" || return 1
  else
    ui_msg "No config generated."
    return 1
  fi

  ui_msg "Done. Files written under:\n- $target_dir/core.json\n- $config_dir/*.json"
  return 0
}

main_menu() {
  ensure_layout || true
  ensure_core_installed || true
  while true; do
    print_header
    if [[ -n "$CURRENT_ROLE" ]]; then
      case "$CURRENT_ROLE" in
        iran) echo "Server role: Iran" ;;
        abroad) echo "Server role: Kharej" ;;
        *) echo "Server role: $CURRENT_ROLE" ;;
      esac
    else
      echo "Server role: (select in wizard)"
    fi
    echo "Base dir: $MANAGEMENT_BASE_DIR"
    echo "----------------------------------------"
    echo "1. Install/Update WaterWall core"
    echo "2. Create new config (wizard)"
    echo "3. List existing configs"
    echo "4. Show active configs (core.json)"
    echo "5. View a config"
    echo "6. Edit a config"
    echo "7. View core.json"
    echo "8. Exit"
    echo ""
    local choice
    read -r -p "Select [1-8]: " choice
    case "${choice:-}" in
      1)
        ensure_core_installed 1 || true
        ;;
      2)
        run_wizard || true
        ;;
      3)
        ensure_base_dir || true
        local config_dir="$MANAGEMENT_BASE_DIR/configs"
        ensure_dir "$config_dir"
        local files
        files=$(ls -1 "$config_dir"/*.json 2>/dev/null | xargs -n1 basename 2>/dev/null || true)
        if [[ -z "$files" ]]; then
          ui_msg "No configs found in $config_dir"
        else
          ui_msg "Configs in $config_dir:\n$files"
        fi
        ;;
      4)
        ensure_base_dir || true
        show_active_configs "$MANAGEMENT_BASE_DIR"
        ;;
      5)
        ensure_base_dir || true
        local config_dir="$MANAGEMENT_BASE_DIR/configs"
        ensure_dir "$config_dir"
        local sel
        sel=$(select_config_file "$config_dir") || true
        if [[ -n "${sel:-}" ]]; then
          ui_msg "File: $sel\n\n$(cat "$sel")"
        fi
        ;;
      6)
        ensure_base_dir || true
        local config_dir="$MANAGEMENT_BASE_DIR/configs"
        ensure_dir "$config_dir"
        local sel
        sel=$(select_config_file "$config_dir") || true
        if [[ -n "${sel:-}" ]]; then
          open_editor "$sel"
        fi
        ;;
      7)
        ensure_base_dir || true
        local core_file="$MANAGEMENT_BASE_DIR/core.json"
        if [[ -f "$core_file" ]]; then
          ui_msg "File: $core_file\n\n$(cat "$core_file")"
        else
          ui_msg "core.json not found in $MANAGEMENT_BASE_DIR"
        fi
        ;;
      8)
        return 0
        ;;
      *)
        ;;
    esac
  done
}

case "${1:-}" in
  --install-core)
    ensure_layout || exit 1
    ensure_core_installed 1 || exit 1
    exit 0
    ;;
  --ensure-core)
    ensure_layout || exit 1
    ensure_core_installed || exit 1
    exit 0
    ;;
esac

main_menu
