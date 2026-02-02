#!/usr/bin/env bash
set -euo pipefail

### WaterWall interactive installer/configurator
### Target dir: /opt/waterwall
### Supports: IRAN server (ReverseServer) and KHAREJ server (ReverseClient)
### Persists settings in /opt/waterwall/.waterwall.env

WW_DIR="/opt/waterwall"
WW_BIN="$WW_DIR/Waterwall"
WW_CORE="$WW_DIR/core.json"
WW_CFG="$WW_DIR/config.json"
WW_ENV="$WW_DIR/.waterwall.env"
SERVICE_FILE="/etc/systemd/system/waterwall.service"
DEFAULT_VERSION="v1.41"

C_RESET="\033[0m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_CYAN="\033[36m"

log()  { echo -e "${C_CYAN}[*]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[-]${C_RESET} $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

pause() { read -r -p "Press Enter to continue..." _; }

detect_arch_asset() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      echo "Waterwall-linux-clang-x64.zip"
      ;;
    aarch64|arm64)
      echo "Waterwall-linux-gcc-arm64.zip"
      ;;
    *)
      err "Unsupported architecture: $arch"
      echo ""
      return 1
      ;;
  esac
}

apt_install() {
  log "Installing dependencies (unzip, curl, libatomic1, python3)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y unzip curl libatomic1 python3 >/dev/null
  ok "Dependencies installed."
}

ensure_dirs() {
  mkdir -p "$WW_DIR/logs" "$WW_DIR/libs"
  ok "Ensured directories: $WW_DIR/{logs,libs}"
}

download_waterwall() {
  local version asset url zip_path
  version="${1:-$DEFAULT_VERSION}"
  asset="$(detect_arch_asset)"
  zip_path="$WW_DIR/$asset"
  url="https://github.com/radkesvat/WaterWall/releases/download/${version}/${asset}"

  log "Downloading WaterWall ${version} asset: $asset"
  log "URL: $url"
  curl -L --fail -o "$zip_path" "$url"
  ok "Downloaded to: $zip_path"

  log "Extracting..."
  unzip -o "$zip_path" -d "$WW_DIR" >/dev/null
  chmod +x "$WW_BIN"
  ok "Installed binary: $WW_BIN"
}

write_core_json() {
  cat > "$WW_CORE" <<'JSON'
{
  "log": {
    "path": "logs/",
    "core":    { "loglevel": "INFO", "file": "core.log", "console": true },
    "network": { "loglevel": "INFO", "file": "network.log", "console": true },
    "dns":     { "loglevel": "SILENT", "file": "dns.log", "console": false },
    "internal":{ "loglevel": "INFO", "file": "internal.log", "console": true }
  },
  "misc": {
    "workers": 0,
    "mtu": 1500,
    "ram-profile": "client",
    "libs-path": "libs/"
  },
  "configs": [
    "config.json"
  ]
}
JSON
  ok "Wrote core.json"
}

json_validate() {
  python3 -m json.tool "$1" >/dev/null
}

port_in_use() {
  local port="$1"
  ss -lntp 2>/dev/null | awk '{print $4,$NF}' | grep -E "[:\\[]${port}\$" -q
}

ask_port_free() {
  local prompt="$1"
  local port
  while true; do
    read -r -p "$prompt" port
    [[ -n "$port" ]] || { warn "Empty. Try again."; continue; }
    [[ "$port" =~ ^[0-9]+$ ]] || { warn "Not a number. Try again."; continue; }
    if (( port < 1 || port > 65535 )); then
      warn "Port out of range. Try again."
      continue
    fi
    if port_in_use "$port"; then
      warn "Port $port is in use. Choose another."
      ss -lntp | grep -E "[:\\[]${port}\b" || true
      continue
    fi
    echo "$port"
    return 0
  done
}

ask_obfs_settings() {
  local method key
  while true; do
    read -r -p "Obfuscator method (only xor, default xor): " method
    method="${method:-xor}"
    if [[ "$method" != "xor" ]]; then
      warn "Only xor is supported right now."
      continue
    fi
    OBFS_METHOD="$method"
    break
  done

  while true; do
    read -r -p "Obfuscator XOR key (0-255, default 123): " key
    key="${key:-123}"
    [[ "$key" =~ ^[0-9]+$ ]] || { warn "Not a number. Try again."; continue; }
    if (( key < 0 || key > 255 )); then
      warn "Out of range. Try again."
      continue
    fi
    OBFS_KEY="$key"
    break
  done
}

prompt_tunnel_node() {
  echo
  echo -e "${C_CYAN}Choose peer tunnel node:${C_RESET}"
  echo "  1) Tcp (plain)"
  echo "  2) Obfuscator (xor)"
  echo "  3) HalfDuplex"
  read -r -p "Select [1-3]: " t
  case "$t" in
    1|"") TUNNEL_NODE="tcp" ;;
    2) TUNNEL_NODE="obfs" ;;
    3) TUNNEL_NODE="halfduplex" ;;
    *) err "Invalid."; return 1 ;;
  esac

  if [[ "$TUNNEL_NODE" == "obfs" ]]; then
    warn "Use the same obfs settings on both servers."
    ask_obfs_settings
  else
    OBFS_METHOD="${OBFS_METHOD:-xor}"
    OBFS_KEY="${OBFS_KEY:-123}"
  fi
}

write_env() {
  # shellcheck disable=SC2129
  cat > "$WW_ENV" <<EOF
# WaterWall saved settings
ROLE="$ROLE"
MODE="$MODE"                   # sameport | twoports
IRAN_IP="$IRAN_IP"
KHAREJ_IP="$KHAREJ_IP"
USER_PORT="$USER_PORT"         # users connect to IRAN:USER_PORT
PEER_PORT="$PEER_PORT"         # reverse peer connects to IRAN:PEER_PORT (same as USER_PORT if MODE=sameport)
XRAY_ADDR="$XRAY_ADDR"         # on KHAREJ server, where to forward (usually 127.0.0.1)
XRAY_PORT="$XRAY_PORT"         # xray inbound port on KHAREJ
MIN_UNUSED="$MIN_UNUSED"       # reverse client minimum-unused
TUNNEL_NODE="$TUNNEL_NODE"     # tcp | obfs | halfduplex (peer link)
OBFS_METHOD="$OBFS_METHOD"     # obfs method (xor)
OBFS_KEY="$OBFS_KEY"           # obfs xor key (0-255)
EOF
  ok "Saved settings: $WW_ENV"
}

load_env() {
  if [[ -f "$WW_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$WW_ENV"
    ok "Loaded settings from $WW_ENV"
    return 0
  fi
  warn "No saved settings found at $WW_ENV"
  return 1
}

normalize_env() {
  TUNNEL_NODE="${TUNNEL_NODE:-tcp}"
  case "$TUNNEL_NODE" in
    tcp|obfs|halfduplex) ;;
    *)
      warn "Unknown TUNNEL_NODE '$TUNNEL_NODE'. Defaulting to tcp."
      TUNNEL_NODE="tcp"
      ;;
  esac

  OBFS_METHOD="${OBFS_METHOD:-xor}"
  OBFS_KEY="${OBFS_KEY:-123}"
  if [[ "$TUNNEL_NODE" == "obfs" ]]; then
    if [[ "$OBFS_METHOD" != "xor" ]]; then
      warn "Unsupported obfs method '$OBFS_METHOD'. Using xor."
      OBFS_METHOD="xor"
    fi
    if [[ ! "$OBFS_KEY" =~ ^[0-9]+$ ]] || (( OBFS_KEY < 0 || OBFS_KEY > 255 )); then
      warn "Invalid OBFS_KEY. Using default 123."
      OBFS_KEY=123
    fi
  fi
}

write_config_iran() {
  local peer_next="reverse_server"
  local peer_extra=""
  if [[ "$TUNNEL_NODE" == "obfs" ]]; then
    peer_next="obfs_server"
    peer_extra=$(cat <<JSON
    {
      "name": "obfs_server",
      "type": "ObfuscatorServer",
      "settings": {
        "method": "${OBFS_METHOD}",
        "xor_key": ${OBFS_KEY}
      },
      "next": "reverse_server"
    }
JSON
)
  elif [[ "$TUNNEL_NODE" == "halfduplex" ]]; then
    peer_next="halfduplex_server"
    peer_extra=$(cat <<'JSON'
    {
      "name": "halfduplex_server",
      "type": "HalfDuplexServer",
      "settings": {},
      "next": "reverse_server"
    }
JSON
)
  fi

  cat > "$WW_CFG" <<JSON
{
  "name": "iran_entry_reverse",
  "nodes": [
    {
      "name": "users_inbound",
      "type": "TcpListener",
      "settings": {
        "address": "0.0.0.0",
        "port": ${USER_PORT},
        "nodelay": true
      },
      "next": "b2"
    },
    {
      "name": "b2",
      "type": "Bridge",
      "settings": { "pair": "b1" }
    },
    {
      "name": "b1",
      "type": "Bridge",
      "settings": { "pair": "b2" },
      "next": "reverse_server"
    },
    {
      "name": "reverse_server",
      "type": "ReverseServer",
      "settings": {},
      "next": "b1"
    },
    {
      "name": "kharej_inbound",
      "type": "TcpListener",
      "settings": {
        "address": "0.0.0.0",
        "port": ${PEER_PORT},
        "nodelay": true,
        "whitelist": ["${KHAREJ_IP}/32"]
      },
      "next": "${peer_next}"
    }
JSON
  if [[ -n "$peer_extra" ]]; then
    cat >> "$WW_CFG" <<JSON
,
$peer_extra
JSON
  fi
  cat >> "$WW_CFG" <<'JSON'
  ]
}
JSON
  json_validate "$WW_CFG"
  ok "Wrote config.json for IRAN"
}

write_config_kharej() {
  local reverse_next="to_iran"
  local peer_extra=""
  if [[ "$TUNNEL_NODE" == "obfs" ]]; then
    reverse_next="obfs_client"
    peer_extra=$(cat <<JSON
    {
      "name": "obfs_client",
      "type": "ObfuscatorClient",
      "settings": {
        "method": "${OBFS_METHOD}",
        "xor_key": ${OBFS_KEY}
      },
      "next": "to_iran"
    }
JSON
)
  elif [[ "$TUNNEL_NODE" == "halfduplex" ]]; then
    reverse_next="halfduplex_client"
    peer_extra=$(cat <<'JSON'
    {
      "name": "halfduplex_client",
      "type": "HalfDuplexClient",
      "settings": {},
      "next": "to_iran"
    }
JSON
)
  fi

  cat > "$WW_CFG" <<JSON
{
  "name": "kharej_reverse_client",
  "nodes": [
    {
      "name": "to_xray",
      "type": "TcpConnector",
      "settings": {
        "nodelay": true,
        "address": "${XRAY_ADDR}",
        "port": ${XRAY_PORT}
      }
    },
    {
      "name": "b1",
      "type": "Bridge",
      "settings": { "pair": "b2" },
      "next": "to_xray"
    },
    {
      "name": "b2",
      "type": "Bridge",
      "settings": { "pair": "b1" },
      "next": "reverse_client"
    },
    {
      "name": "reverse_client",
      "type": "ReverseClient",
      "settings": {
        "minimum-unused": ${MIN_UNUSED}
      },
      "next": "${reverse_next}"
    }
JSON
  if [[ -n "$peer_extra" ]]; then
    cat >> "$WW_CFG" <<JSON
,
$peer_extra
JSON
  fi
  cat >> "$WW_CFG" <<JSON
,
    {
      "name": "to_iran",
      "type": "TcpConnector",
      "settings": {
        "nodelay": true,
        "address": "${IRAN_IP}",
        "port": ${PEER_PORT}
      }
    }
  ]
}
JSON
  json_validate "$WW_CFG"
  ok "Wrote config.json for KHAREJ"
}

create_systemd_service() {
  cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=WaterWall
After=network.target

[Service]
WorkingDirectory=${WW_DIR}
ExecStart=${WW_BIN}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable --now waterwall
  ok "systemd service created and started: waterwall"
}

service_status() {
  systemctl status waterwall --no-pager || true
}

service_logs_tail() {
  journalctl -u waterwall -n 100 --no-pager || true
}

restart_service() {
  systemctl restart waterwall
  ok "Restarted waterwall"
}

stop_service() {
  systemctl stop waterwall || true
  ok "Stopped waterwall"
}

uninstall_all() {
  warn "This will stop service and remove /opt/waterwall and systemd service."
  read -r -p "Type YES to continue: " confirm
  [[ "$confirm" == "YES" ]] || { warn "Cancelled."; return; }

  systemctl stop waterwall 2>/dev/null || true
  systemctl disable waterwall 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload || true
  rm -rf "$WW_DIR"
  ok "Uninstalled."
}

prompt_role_and_settings() {
  echo
  echo -e "${C_CYAN}Choose server role:${C_RESET}"
  echo "  1) IRAN (entry) - ReverseServer"
  echo "  2) KHAREJ (exit) - ReverseClient"
  read -r -p "Select [1-2]: " r
  case "$r" in
    1) ROLE="IRAN" ;;
    2) ROLE="KHAREJ" ;;
    *) err "Invalid."; return 1 ;;
  esac

  echo
  echo -e "${C_CYAN}Choose tunnel mode:${C_RESET}"
  echo "  1) sameport   (users + reverse-peer on same port, e.g. 443)"
  echo "  2) twoports   (users on USER_PORT, reverse-peer on PEER_PORT, e.g. 443/4443) [recommended]"
  read -r -p "Select [1-2]: " m
  case "$m" in
    1) MODE="sameport" ;;
    2) MODE="twoports" ;;
    *) err "Invalid."; return 1 ;;
  esac

  if ! prompt_tunnel_node; then
    return 1
  fi

  echo
  read -r -p "IRAN IP (entry server public IP): " IRAN_IP
  read -r -p "KHAREJ IP (exit server public IP): " KHAREJ_IP

  if [[ "$MODE" == "sameport" ]]; then
    USER_PORT="$(ask_port_free "User listening port on IRAN (e.g. 443): ")"
    PEER_PORT="$USER_PORT"
  else
    USER_PORT="$(ask_port_free "User listening port on IRAN (e.g. 443): ")"
    # For peer port, if configuring on IRAN host we'll check local port; on KHAREJ host it doesn't matter.
    PEER_PORT="$(ask_port_free "Reverse peer port on IRAN (e.g. 4443): ")"
    if [[ "$PEER_PORT" == "$USER_PORT" ]]; then
      warn "You chose same ports. That's effectively sameport mode."
    fi
  fi

  # KHAREJ specifics
  if [[ "$ROLE" == "KHAREJ" ]]; then
    read -r -p "XRAY listen address on KHAREJ (default 127.0.0.1): " XRAY_ADDR
    XRAY_ADDR="${XRAY_ADDR:-127.0.0.1}"
    read -r -p "XRAY inbound port on KHAREJ (default 443): " XRAY_PORT
    XRAY_PORT="${XRAY_PORT:-443}"
    read -r -p "ReverseClient minimum-unused (default 8): " MIN_UNUSED
    MIN_UNUSED="${MIN_UNUSED:-8}"
  else
    # still store defaults
    XRAY_ADDR="${XRAY_ADDR:-127.0.0.1}"
    XRAY_PORT="${XRAY_PORT:-443}"
    MIN_UNUSED="${MIN_UNUSED:-8}"
  fi

  write_env
}

apply_config_from_env() {
  load_env || return 1
  normalize_env

  ensure_dirs
  write_core_json

  if [[ "$ROLE" == "IRAN" ]]; then
    # On IRAN host: ensure USER_PORT and PEER_PORT are free
    if port_in_use "$USER_PORT"; then
      warn "USER_PORT $USER_PORT is in use on this host."
      USER_PORT="$(ask_port_free "Pick a free USER_PORT: ")"
      [[ "$MODE" == "sameport" ]] && PEER_PORT="$USER_PORT"
    fi
    if port_in_use "$PEER_PORT"; then
      warn "PEER_PORT $PEER_PORT is in use on this host."
      PEER_PORT="$(ask_port_free "Pick a free PEER_PORT: ")"
    fi

    write_config_iran
  else
    write_config_kharej
  fi

  # update env with any changed ports
  write_env
  create_systemd_service
  service_status
}

download_menu() {
  ensure_dirs
  apt_install
  read -r -p "WaterWall version (default ${DEFAULT_VERSION}): " v
  v="${v:-$DEFAULT_VERSION}"
  download_waterwall "$v"
}

edit_env_quick() {
  ensure_dirs
  if ! have_cmd nano; then
    apt-get update -y >/dev/null
    apt-get install -y nano >/dev/null || true
  fi
  [[ -f "$WW_ENV" ]] || { warn "No $WW_ENV yet. Create config first."; return; }
  nano "$WW_ENV"
  ok "Edited $WW_ENV. Now choose 'Apply config from saved settings' to regenerate."
}

show_summary() {
  echo
  echo -e "${C_CYAN}Current files:${C_RESET}"
  ls -la "$WW_DIR" || true
  echo
  echo -e "${C_CYAN}Saved settings:${C_RESET}"
  if [[ -f "$WW_ENV" ]]; then
    sed -n '1,200p' "$WW_ENV"
  else
    echo "(none)"
  fi
  echo
  echo -e "${C_CYAN}Listening ports:${C_RESET}"
  ss -lntp | head -n 30 || true
  echo
}

main_menu() {
  while true; do
    echo
    echo -e "${C_CYAN}========== WaterWall Manager ==========${C_RESET}"
    echo "Dir: $WW_DIR"
    echo "1) Install deps + Download/Update WaterWall binary"
    echo "2) Create/Update settings (role, IPs, ports) and save"
    echo "3) Apply config from saved settings + create systemd service"
    echo "4) Quick edit saved settings (.waterwall.env) [nano]"
    echo "5) Show status + last logs"
    echo "6) Restart service"
    echo "7) Stop service"
    echo "8) Show summary (files/settings/listening)"
    echo "9) Uninstall WaterWall"
    echo "0) Exit"
    read -r -p "Select: " choice

    case "$choice" in
      1) download_menu; pause ;;
      2) prompt_role_and_settings; pause ;;
      3) apply_config_from_env; pause ;;
      4) edit_env_quick; pause ;;
      5) service_status; echo; service_logs_tail; pause ;;
      6) restart_service; pause ;;
      7) stop_service; pause ;;
      8) show_summary; pause ;;
      9) uninstall_all; pause ;;
      0) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

### Entry
require_root
ensure_dirs
main_menu
