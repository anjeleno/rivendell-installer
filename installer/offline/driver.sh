#!/usr/bin/env bash
set -euo pipefail

# Offline installer driver (TUI first, GUI optional if zenity found)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$SCRIPT_DIR/payload"
PKG_DIR="$SCRIPT_DIR/packages"
WORK_DIR="/tmp/rivendell-cloud-installer"

mkdir -p "$WORK_DIR"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

use_gui=false
if have_cmd zenity && [[ -n "${DISPLAY:-}" ]]; then
  use_gui=true
fi

ask_select() {
  local title="$1"; shift
  local choices=("$@")
  if $use_gui; then
    zenity --list --title "$title" --column Options "${choices[@]}"
  else
    whiptail --title "$title" --menu "Use arrows/Enter to choose" 15 60 4 "${choices[@]}" 3>&1 1>&2 2>&3
  fi
}

ask_yesno() {
  local title="$1"
  if $use_gui; then
    zenity --question --text "$title"
    return $?
  else
    whiptail --yesno "$title" 10 60
    return $?
  fi
}

ask_input() {
  local prompt="$1"; local default_val="$2"
  if $use_gui; then
    zenity --entry --title "Input" --text "$prompt" --entry-text "$default_val"
  else
    whiptail --inputbox "$prompt" 10 60 "$default_val" 3>&1 1>&2 2>&3
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root (or via sudo)." >&2
    exit 1
  fi
}

detect_series() {
  lsb_release -rs 2>/dev/null | cut -d. -f1,2
}

series="$(detect_series)"
case "$series" in
  22.04|24.04) :;;
  *) echo "Unsupported Ubuntu release: $series. Supported: 22.04, 24.04" >&2; exit 1;;
esac

require_root

# Gather choices
install_type=$(ask_select "Installation Type" Standalone Server Client || echo "Standalone")
hostname_val=$(ask_input "Hostname (Rivendell requires match)" "onair" || echo "onair")
set_tz=false; if ask_yesno "Configure timezone now?"; then set_tz=true; fi
enable_ufw=false; if ask_yesno "Enable UFW and open required ports?"; then enable_ufw=true; fi
harden_ssh=false; if ask_yesno "Harden SSH (disable password auth)? Ensure SSH keys work first."; then harden_ssh=true; fi
install_mate=false; if ask_yesno "Install MATE desktop (optional)?"; then install_mate=true; fi

# Decide target user
target_user="${SUDO_USER:-${USER}}"
if [[ "$target_user" == "root" ]]; then
  create_rd=true
  target_user=rd
else
  create_rd=false
fi

echo "Series: $series"
echo "Type: $install_type"
echo "Hostname: $hostname_val"
echo "Target user: $target_user (create rd: $create_rd)"

# TODO: Implement the full installation flow mirroring rivendell-auto-install.sh
# Steps (idempotent):
# 1) Set hostname if needed; optionally configure timezone (tzdata)
# 2) Configure a local apt repo from $PKG_DIR/$series and install exact .debs, including Rivendell 4.3.0
# 3) Create/prepare user: groups (audio, sudo as appropriate), limits.conf RT/memlock, pulseaudio autospawn=no
# 4) Install xrdp; do not force ~/.xsession; rely on default x-session-manager; optionally install MATE
# 5) Deploy APPS payload to /usr/share/rivendell-cloud and copy user assets (configs, shortcuts) to $target_user
# 6) Configure Icecast (copy icecast.xml), enable and start icecast2
# 7) Create /var/www/html/meta.txt owned by pypad
# 8) Fix pypad.py on 24.04 if needed
# 9) Apply Qt5/XCB xRDP root fix (symlink rd's .Xauthority to root)
# 10) Extract MariaDB password from /etc/rd.conf and import APPS/sql/RDDB_v430_Cloud.sql
# 11) Optionally enable UFW rules and harden SSH (with backups of config)
# 12) Pin/Hold rivendell packages at 4.3.0
# 13) Print reboot recommendation

echo "[INFO] Driver scaffold complete. Implementation pending."

# Example implementation for the Qt5/XCB fix (will be gated inside the full flow):
qt5_xcb_fix() {
  local rd_home="/home/rd"
  if id -u rd >/dev/null 2>&1 && [[ -f "$rd_home/.Xauthority" ]]; then
    ln -sf "$rd_home/.Xauthority" /root/.Xauthority
    echo "[OK] Linked $rd_home/.Xauthority to /root/.Xauthority"
  else
    echo "[WARN] rd user or $rd_home/.Xauthority not present; skipping Qt5/XCB fix"
  fi
}

