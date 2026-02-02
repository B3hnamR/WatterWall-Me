#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/B3hnamR/WatterWall-Me/main"
WIZARD_URL="$REPO_RAW_BASE/waterwall-wizard.sh"
INSTALL_DIR="${WATERWALL_DIR:-/opt/waterwall}"
WIZARD_PATH="$INSTALL_DIR/waterwall-wizard.sh"

SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

need_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi
  if [[ -n "$SUDO" ]]; then
    return 0
  fi
  echo "This installer requires root or sudo." >&2
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

main() {
  need_root
  $SUDO mkdir -p "$INSTALL_DIR"
  if ! download_file "$WIZARD_URL" "$WIZARD_PATH"; then
    echo "Failed to download: $WIZARD_URL" >&2
    exit 1
  fi
  $SUDO chmod +x "$WIZARD_PATH"
  $SUDO ln -sf "$WIZARD_PATH" /usr/local/bin/waterwall-wizard >/dev/null 2>&1 || true
  "$WIZARD_PATH" --ensure-core

  echo ""
  echo "Installed. Run: waterwall-wizard"
  if [[ -t 0 ]]; then
    "$WIZARD_PATH"
  fi
}

main "$@"
