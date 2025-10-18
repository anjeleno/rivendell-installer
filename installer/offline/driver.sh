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

log() { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get -yq install "$@"
}

ensure_packages() {
  log "Installing base dependencies..."
  apt-get update -yq || true
  apt_install software-properties-common apt-transport-https ca-certificates gnupg \
    whiptail curl jq git sudo
}

set_hostname() {
  if [[ -n "$hostname_val" && "$hostname_val" != "$(hostname)" ]]; then
    log "Setting hostname to $hostname_val"
    hostnamectl set-hostname "$hostname_val" || true
    sed -i "/127.0.1.1/d" /etc/hosts || true
    echo "127.0.1.1 $hostname_val" >> /etc/hosts
  fi
}

set_timezone() {
  if $set_tz; then
    tz=$(ask_input "Enter timezone (e.g. America/Chicago)" "$(cat /etc/timezone 2>/dev/null || echo UTC)" || echo "UTC")
    log "Setting timezone to $tz"
    timedatectl set-timezone "$tz" || true
  fi
}

ensure_user() {
  if $create_rd; then
    if ! id -u "$target_user" >/dev/null 2>&1; then
      log "Creating user $target_user"
      useradd -m -s /bin/bash "$target_user"
      passwd -l "$target_user" || true
    fi
  fi
  log "Adding $target_user to groups"
  usermod -aG sudo,audio,pulse,pulse-access,adm,cdrom,video "$target_user" || true
  mkdir -p "/home/$target_user"
  chown -R "$target_user:$target_user" "/home/$target_user"
}

configure_limits() {
  log "Configuring realtime and memlock limits"
  cat >/etc/security/limits.d/rivendell.conf <<EOF
@audio   -  rtprio     95
@audio   -  memlock    unlimited
EOF
}

install_local_debs() {
  local d="$PKG_DIR/$series"
  log "Installing Rivendell 4.3.0 from local packages: $d"
  if compgen -G "$d/*.deb" >/dev/null; then
    apt_install gdebi-core || true
    # Install in a single dpkg invocation to satisfy inter-deps; then fix with apt -f
    dpkg -i "$d"/*.deb || true
    apt-get -yq -f install
  else
    fail "No .deb packages found in $d"
  fi
}

install_xrdp_desktop() {
  log "Installing xrdp and optional desktop"
  apt_install xrdp
  if $install_mate; then
    apt_install ubuntu-mate-desktop || apt_install mate-desktop-environment
  fi
  systemctl enable xrdp || true
  systemctl restart xrdp || true
}

deploy_apps_payload() {
  local dst="/usr/share/rivendell-cloud"
  log "Deploying APPS payload to $dst"
  mkdir -p "$dst"
  rsync -a "$PAYLOAD_DIR/" "$dst/"
  # Shortcuts to user Desktop
  local desk="/home/$target_user/Desktop"
  mkdir -p "$desk"
  if compgen -G "$dst/APPS/Shortcuts/*.desktop" >/dev/null; then
    rsync -a "$dst/APPS/Shortcuts/" "$desk/"
    chown -R "$target_user:$target_user" "$desk"
    chmod +x "$desk"/*.desktop 2>/dev/null || true
  fi
  # Configs to user's home as needed
  mkdir -p "/home/$target_user/.config"
  if [[ -d "$dst/APPS/configs" ]]; then
    rsync -a "$dst/APPS/configs/" "/home/$target_user/.config/"
    chown -R "$target_user:$target_user" "/home/$target_user/.config"
  fi
}

configure_icecast() {
  local src="/usr/share/rivendell-cloud/APPS/icecast.xml"
  if [[ -f "$src" ]]; then
    log "Configuring Icecast"
    apt_install icecast2 || true
    install -Dm644 "$src" /etc/icecast2/icecast.xml
    sed -i 's/ENABLE=false/ENABLE=true/' /etc/default/icecast2 || true
    systemctl enable icecast2 || true
    systemctl restart icecast2 || true
  fi
}

web_meta_file() {
  log "Creating /var/www/html/meta.txt (owned by pypad if exists)"
  mkdir -p /var/www/html
  touch /var/www/html/meta.txt
  if id -u pypad >/dev/null 2>&1; then
    chown pypad:pypad /var/www/html/meta.txt
  fi
}

qt5_xcb_fix() {
  # For xRDP sessions running Rivendell as root tools invoking Qt
  local rd_home="/home/$target_user"
  if [[ -f "$rd_home/.Xauthority" ]]; then
    ln -sf "$rd_home/.Xauthority" /root/.Xauthority || true
    log "Linked $rd_home/.Xauthority to /root/.Xauthority"
  else
    log "Skipping Qt5/XCB link; no $rd_home/.Xauthority yet"
  fi
}

import_database() {
  local sql="/usr/share/rivendell-cloud/APPS/RDDB_v430_Cloud.sql"
  if [[ -f "$sql" ]]; then
    log "Importing MariaDB schema from APPS"
    # Extract credentials from rd.conf if present
    local cnf="/etc/rd.conf"
    local db="Rivendell"
    local user="rduser"
    local pass="letmein"
    [[ -f "$cnf" ]] && db=$(awk -F= '/^Database=/ {print $2}' "$cnf" | tr -d ' \r') || true
    [[ -f "$cnf" ]] && user=$(awk -F= '/^DbUser=/ {print $2}' "$cnf" | tr -d ' \r') || true
    [[ -f "$cnf" ]] && pass=$(awk -F= '/^DbPassword=/ {print $2}' "$cnf" | tr -d ' \r') || true
    apt_install mariadb-client || true
    mysql -u"$user" -p"$pass" "$db" < "$sql" || log "MySQL import skipped/failed; ensure DB is reachable and creds are correct"
  fi
}

firewall_and_ssh() {
  if $enable_ufw; then
    log "Configuring UFW"
    apt_install ufw || true
    ufw allow OpenSSH || true
    ufw allow 3389/tcp || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw --force enable || true
  fi
  if $harden_ssh; then
    log "Hardening SSH"
    install -Dm600 /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    systemctl restart ssh || systemctl restart sshd || true
  fi
}

pin_rivendell() {
  log "Pinning Rivendell packages to 4.3.0"
  apt-mark hold rivendell rivendell-dev rivendell-importers rivendell-select rivendell-webapi rivendell-webget || true
}

post_notes() {
  log "Installation complete. A reboot is recommended."
}

# Execute steps
ensure_packages
set_hostname
set_timezone
ensure_user
configure_limits
install_local_debs
install_xrdp_desktop
deploy_apps_payload
configure_icecast
web_meta_file
qt5_xcb_fix
import_database
firewall_and_ssh
pin_rivendell
post_notes

