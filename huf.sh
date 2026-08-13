#!/usr/bin/env bash
# HUF LXC launcher for Proxmox VE.
# Provides the full-screen Community Scripts installer UI, then loads this
# repository's HUF-specific container installer.
set -Eeuo pipefail

APP="HUF"
REPO_RAW="https://raw.githubusercontent.com/SahilUX/huf-proxmox-helper/main"
INSTALL_URL="${REPO_RAW}/install-huf-lxc.sh"
BUILD_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func"

# Prescribed defaults. CT ID is intentionally fixed rather than auto-selected.
var_ctid="${var_ctid:-100}"
var_tags="${var_tags:-ai;automation}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-30}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"

# Community Scripts' build.func normally fetches its installer from its own
# repository. Replace only that URL with this repository's reviewed installer.
BUILD_FUNC="$({ curl -fsSL "$BUILD_URL"; })"
[[ ${#BUILD_FUNC} -gt 1000 ]] || { echo "Unable to download Community Scripts build functions." >&2; exit 1; }
BUILD_FUNC="$(printf '%s' "$BUILD_FUNC" | sed 's|https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/install/${var_install}.sh|https://raw.githubusercontent.com/SahilUX/huf-proxmox-helper/main/install-huf-lxc.sh|g')"
source /dev/stdin <<<"$BUILD_FUNC"

header_info "$APP"
variables
color
catch_errors

# Do not silently select another ID: this helper is deliberately CT 100.
if qm status "$var_ctid" >/dev/null 2>&1 || pct status "$var_ctid" >/dev/null 2>&1; then
  msg_error "CT ID ${var_ctid} is already in use. This HUF helper is fixed to CT ID 100. Free CT/VM 100 before continuing."
  exit 1
fi

FRAPPE_MAJOR="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "HUF: Frappe Bench Version" \
  --radiolist "Choose the Frappe Bench major version for a fresh HUF installation.\n\nFrappe 15 is the supported default. Frappe 16 is currently blocked because HUF's current LiteLLM constraint conflicts with Python 3.14." \
  18 82 3 \
  "14" "Legacy, experimental HUF option" OFF \
  "15" "Recommended and default HUF target" ON \
  "16" "Unsupported until HUF upstream resolves Python 3.14 compatibility" OFF \
  3>&1 1>&2 2>&3)" || exit 0

if [[ "$FRAPPE_MAJOR" == "16" && "${HUF_ALLOW_UNSUPPORTED_V16:-0}" != "1" ]]; then
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "HUF: Unsupported Version" --msgbox \
    "Frappe 16 is not currently usable for HUF. Its Python 3.14 runtime conflicts with HUF's present LiteLLM requirement.\n\nChoose Frappe 15, or wait for a compatible HUF upstream release." 13 78
  exit 1
fi
export FRAPPE_MAJOR

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}${CL}"
echo -e "${INFO}${YW}Credentials are stored inside the LXC and are intentionally not printed in logs:${CL}"
echo -e "${TAB}${BGN}pct exec 100 -- cat /root/huf.credentials${CL}"
