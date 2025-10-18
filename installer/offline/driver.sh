#!/usr/bin/env bash
set -euo pipefail

# Offline installer driver (TUI first, GUI optional if zenity found)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$SCRIPT_DIR/payload"
PKG_DIR="$SCRIPT_DIR/packages"
WORK_DIR="/tmp/rivendell-installer"

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

# Hidden password prompt
ask_password() {
  local prompt="$1"
  if $use_gui; then
    zenity --entry --title "Password" --text "$prompt" --hide-text
  else
    whiptail --passwordbox "$prompt" 10 60 3>&1 1>&2 2>&3
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

# Decide target user (for desktop seeding), but always provision rd for Rivendell
target_user="${SUDO_USER:-${USER}}"
create_rd=true

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
  # Ensure rd exists and is in key groups
  if ! id -u rd >/dev/null 2>&1; then
    log "Creating user rd"
    useradd -m -s /bin/bash rd
    # Prompt and set a password for rd
    local pw1 pw2 attempts=0
    while (( attempts < 3 )); do
      pw1=$(ask_password "Set password for user 'rd'") || pw1=""
      pw2=$(ask_password "Confirm password for user 'rd'") || pw2=""
      if [[ -n "$pw1" && "$pw1" == "$pw2" ]]; then
        echo "rd:$pw1" | chpasswd && break
      fi
      attempts=$((attempts+1))
      log "Passwords did not match or were empty. Try again ($attempts/3)."
    done
    if (( attempts == 3 )); then
      log "Password for rd not set (skipped after 3 attempts). You can set it later with 'passwd rd'."
    fi
  fi
  usermod -aG sudo,audio,pulse,pulse-access,adm,cdrom,video rd || true
  mkdir -p /home/rd /home/rd/imports /home/rd/logs
  chown -R rd:rd /home/rd

  # Also make sure target_user has a home and ownership (for Desktop seeding)
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

# Additional workstation apps Rivendell users expect
install_media_apps() {
  log "Installing media apps (qjackctl, vlc, liquidsoap, jackd2)"
  apt_install qjackctl vlc liquidsoap jackd2 pulseaudio-module-jack || true
}

install_xrdp_desktop() {
  log "Installing xrdp and optional desktop"
  apt_install xrdp dbus-x11
  if $install_mate; then
    apt_install ubuntu-mate-desktop || apt_install mate-desktop-environment
  fi
  systemctl enable xrdp || true
  systemctl restart xrdp || true
}

suppress_mate_power_manager() {
  # Disable mate-power-manager autostart to avoid xRDP crash dialog
  local sys_autostart="/etc/xdg/autostart/mate-power-manager.desktop"
  [[ -f "$sys_autostart" ]] || return 0
  for u in "$target_user" rd; do
    if id -u "$u" >/dev/null 2>&1; then
      local autostart="/home/$u/.config/autostart"
      mkdir -p "$autostart"
      install -m 644 "$sys_autostart" "$autostart/mate-power-manager.desktop" 2>/dev/null || true
      echo "Hidden=true" >> "$autostart/mate-power-manager.desktop"
      chown -R "$u:$u" "/home/$u/.config"
    fi
  done
}

deploy_apps_payload() {
  local sysdst="/usr/share/rivendell-cloud"
  local rddst="/home/rd/imports/APPS"
  log "Deploying APPS payload to rd home: $rddst"
  mkdir -p "$sysdst" "$rddst"
  rsync -a "$PAYLOAD_DIR/" "$sysdst/"
  rsync -a "$sysdst/APPS/" "$rddst/"
  chown -R rd:rd "/home/rd/imports" "/home/rd/logs"
  # Ensure required rd folders and logs exist
  mkdir -p /home/rd/imports/RECONCILE /home/rd/Music /home/rd/logs
  touch /home/rd/logs/soap.log /home/rd/logs/dropbox.log
  chown -R rd:rd /home/rd/imports /home/rd/Music /home/rd/logs
  
  # Compatibility symlink for older paths
  ln -sfn /home/rd/imports /rivendell-installer

  # Ensure executability for scripts and shortcuts in APPS
  if [[ -d "$rddst" ]]; then
    find "$rddst" -type f \( -name "*.sh" -o -name "*.desktop" -o -name "*.liq" -o -name "stl.sh" -o -name "autologgen.sh" -o -name "reconcile-traffic.sh" -o -name "stereo_tool_gui_jack_64_1030" \) -exec chmod +x {} + 2>/dev/null || true
    # Rewrite any legacy/system paths within scripts to rd home
    while IFS= read -r -d '' f; do
      sed -i 's|/usr/share/rivendell-cloud/APPS|/home/rd/imports/APPS|g' "$f"
      sed -i 's|/rivendell-installer/APPS|/home/rd/imports/APPS|g' "$f"
      sed -i 's|/home/.*/rivendell-installer/APPS|/home/rd/imports/APPS|g' "$f"
      sed -i 's|/home/.*/imports/APPS|/home/rd/imports/APPS|g' "$f"
      sed -i 's|/var/log/rivendell-cloud/soap.log|/home/rd/logs/soap.log|g' "$f"
    done < <(find "$rddst" -type f \( -name "*.sh" -o -name "*.liq" -o -name "*.desktop" -o -name "*.conf" -o -name "*.xml" \) -print0)
  fi

  # System applications menu uses rd-based Exec
  if compgen -G "$rddst/Shortcuts/*.desktop" >/dev/null; then
    mkdir -p /usr/share/applications
    while IFS= read -r -d '' f; do
      base=$(basename "$f")
      install -m 644 "$f" "/usr/share/applications/$base"
    done < <(find "$rddst/Shortcuts" -type f -name "*.desktop" -print0)
  fi

  # Helper to copy shortcuts to a user's Desktop
  copy_shortcuts_to_user() {
    local u="$1"; local home="/home/$u"; local desk="$home/Desktop"
    [[ -d "$home" ]] || return 0
    mkdir -p "$desk"
    if compgen -G "$rddst/Shortcuts/*.desktop" >/dev/null; then
      rsync -a "$rddst/Shortcuts/" "$desk/"
      chown -R "$u:$u" "$desk"
      chmod +x "$desk"/*.desktop 2>/dev/null || true
    fi
  }

  # Seed shortcuts for target user and for rd if present
  copy_shortcuts_to_user "$target_user"
  copy_shortcuts_to_user rd

  # Configs to user's home as needed
  mkdir -p "/home/$target_user/.config"
  if [[ -d "$rddst/configs" ]]; then
    rsync -a "$rddst/configs/" "/home/$target_user/.config/"
    chown -R "$target_user:$target_user" "/home/$target_user/.config"
  fi
  # Also seed configs for rd
  mkdir -p "/home/rd/.config"
  if [[ -d "$rddst/configs" ]]; then
    rsync -a "$rddst/configs/" "/home/rd/.config/"
    chown -R rd:rd "/home/rd/.config"
    # Place specific configs where apps expect them
    mkdir -p "/home/rd/.config/vlc" "/home/rd/.config/rncbc.org"
    [[ -f "$rddst/configs/vlcrc" ]] && install -m 644 "$rddst/configs/vlcrc" "/home/rd/.config/vlc/vlcrc"
    [[ -f "$rddst/configs/vlc-qt-interface.conf" ]] && install -m 644 "$rddst/configs/vlc-qt-interface.conf" "/home/rd/.config/vlc/vlc-qt-interface.conf"
    [[ -f "$rddst/configs/QjackCtl.conf" ]] && install -m 644 "$rddst/configs/QjackCtl.conf" "/home/rd/.config/rncbc.org/QjackCtl.conf"
    [[ -f "$rddst/configs/.stereo_tool_gui_jack_64_1030.rc" ]] && install -m 644 "$rddst/configs/.stereo_tool_gui_jack_64_1030.rc" "/home/rd/.stereo_tool_gui_jack_64_1030.rc"
    chown -R rd:rd "/home/rd/.config"
    chown rd:rd "/home/rd/.stereo_tool_gui_jack_64_1030.rc" 2>/dev/null || true
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
  # Prefer XCB for Qt apps in xRDP sessions
  echo 'export QT_QPA_PLATFORM=xcb' > /etc/profile.d/qt-xcb.sh
  chmod 644 /etc/profile.d/qt-xcb.sh
  # Also set per-user for common users (target and rd if exists)
  for u in "$target_user" rd; do
    if id -u "$u" >/dev/null 2>&1; then
      local xrc="/home/$u/.xsessionrc"
      grep -q 'QT_QPA_PLATFORM=xcb' "$xrc" 2>/dev/null || echo 'export QT_QPA_PLATFORM=xcb' >> "$xrc"
      chown "$u:$u" "$xrc" || true
    fi
  done

  # Share Xauthority so root-run Qt apps can display in xRDP
  if [[ -f "/home/rd/.Xauthority" ]]; then
    ln -sfn "/home/rd/.Xauthority" "/root/.Xauthority"
  fi
}

# After the first xRDP login, link rd's Xauthority to root automatically
setup_xauth_autolink() {
  local svc="/etc/systemd/system/rivendell-xauth-link.service"
  local path="/etc/systemd/system/rivendell-xauth-link.path"
  cat >"$svc" <<'EOF'
[Unit]
Description=Link rd .Xauthority to root for xRDP Qt apps

[Service]
Type=oneshot
ExecStart=/bin/ln -sfn /home/rd/.Xauthority /root/.Xauthority
ConditionPathExists=/home/rd/.Xauthority
EOF
  cat >"$path" <<'EOF'
[Unit]
Description=Watch for rd .Xauthority

[Path]
PathExists=/home/rd/.Xauthority

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || true
  systemctl enable --now rivendell-xauth-link.path || true
}

configure_rd_conf() {
  # Prepare /etc/rd.conf with DB credentials prior to Rivendell install
  local db="Rivendell" user="rduser" pass="hackme" host="localhost"
  local u_in d_in p_in
  u_in=$(ask_input "Database username" "$user" || echo "$user")
  d_in=$(ask_input "Database name" "$db" || echo "$db")
  p_in=$(ask_password "Database password (leave blank to keep default)" || true)
  [[ -n "$u_in" ]] && user="$u_in"
  [[ -n "$d_in" ]] && db="$d_in"
  [[ -n "$p_in" ]] && pass="$p_in"
  cat >/etc/rd.conf <<EOF
[mySQL]
Driver=QMYSQL
DbUser=$user
DbPassword=$pass
Database=$db
Hostname=$host
EOF
}

# Ensure MariaDB is installed and running before Rivendell packages
ensure_mariadb() {
  log "Installing and starting MariaDB server"
  apt_install mariadb-server mariadb-client || true
  systemctl enable --now mariadb || true
  # Wait briefly for server availability
  local i=0
  until mysqladmin ping >/dev/null 2>&1; do
    sleep 1; i=$((i+1)); [[ $i -ge 20 ]] && break
  done
}

# After Rivendell installs and generates /etc/rd.conf, finalize DB tasks
finalize_rivendell_db() {
  # Only initialize local DB for Standalone or Server installs
  case "$install_type" in
    Standalone|Server) :;;
    *) return 0;;
  esac

  # Read the credentials Rivendell generated
  if [[ ! -f /etc/rd.conf ]]; then
    log "/etc/rd.conf not present; skipping DB finalization"
    return 0
  fi

  log "Finalizing Rivendell database"
  # Parse only within the [mySQL] section
  local db user pass host
  db=$(awk -F= '/^\[mySQL\]/{s=1;next}/^\[/{s=0} s&&/^Database=/{print $2}' /etc/rd.conf | tr -d ' \r')
  # Rivendell uses 'Loginname='; older templates may use 'DbUser='
  user=$(awk -F= '/^\[mySQL\]/{s=1;next}/^\[/{s=0} s&&/^Loginname=/{print $2}' /etc/rd.conf | tr -d ' \r')
  [[ -n "$user" ]] || user=$(awk -F= '/^\[mySQL\]/{s=1;next}/^\[/{s=0} s&&/^DbUser=/{print $2}' /etc/rd.conf | tr -d ' \r')
  # Rivendell uses 'Password='; older templates may use 'DbPassword='
  pass=$(awk -F= '/^\[mySQL\]/{s=1;next}/^\[/{s=0} s&&/^Password=/{print $2}' /etc/rd.conf | tr -d ' \r')
  [[ -n "$pass" ]] || pass=$(awk -F= '/^\[mySQL\]/{s=1;next}/^\[/{s=0} s&&/^DbPassword=/{print $2}' /etc/rd.conf | tr -d ' \r')
  host=$(awk -F= '/^\[mySQL\]/{s=1;next}/^\[/{s=0} s&&/^Hostname=/{print $2}' /etc/rd.conf | tr -d ' \r')
  [[ -z "$host" ]] && host=localhost

  if [[ -z "$db" || -z "$user" || -z "$pass" ]]; then
    log "Unable to parse DB credentials from /etc/rd.conf; found db='$db' user='$user' pass_len=${#pass}. Skipping custom DB import."
  else
    # Idempotence marker to avoid clobbering on re-runs unless schema changes
    local stamp_dir="/var/lib/rivendell-cloud"; local stamp_file="$stamp_dir/db.finalized"
    mkdir -p "$stamp_dir"

    # Determine SQL payload path
    local sql="/usr/share/rivendell-cloud/APPS/RDDB_v430_Cloud.sql"
    [[ -f "$sql" ]] || sql="$PAYLOAD_DIR/APPS/RDDB_v430_Cloud.sql"

    # Helper to exec as MariaDB root via unix_socket
    mysql_root() { mysql --protocol=socket -uroot -NBe "$1"; }

    # Ensure server is accepting connections
    local i=0
    until mysql --protocol=socket -uroot -e 'SELECT 1' >/dev/null 2>&1; do
      sleep 1; i=$((i+1)); [[ $i -ge 20 ]] && break
    done

  # Stop rivendell while altering DB
  systemctl stop rivendell || true

  # Create user and DB, grant privileges
  log "Ensuring MySQL user '$user' and database '$db' exist"
  mysql_root "CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass}'" || true
  mysql_root "CREATE USER IF NOT EXISTS '${user}'@'127.0.0.1' IDENTIFIED BY '${pass}'" || true
  mysql_root "ALTER USER '${user}'@'localhost' IDENTIFIED BY '${pass}'" || true
  mysql_root "ALTER USER '${user}'@'127.0.0.1' IDENTIFIED BY '${pass}'" || true
  mysql_root "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci"
  mysql_root "GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'localhost'"
  mysql_root "GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'127.0.0.1'"
  mysql_root "FLUSH PRIVILEGES"

    # If we have a custom schema, replace the DB contents with it
    if [[ -f "$sql" ]]; then
      log "Importing custom Rivendell schema from $(basename "$sql")"
      # Drop and recreate to ensure a clean import
      mysql_root "DROP DATABASE IF EXISTS \`${db}\`"
      mysql_root "CREATE DATABASE \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci"
      # Ensure privileges after recreation
      mysql_root "GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'localhost'"
      mysql_root "GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'127.0.0.1'"
      mysql_root "FLUSH PRIVILEGES"
      if mysql --protocol=socket -uroot "$db" < "$sql"; then
        date +%s > "$stamp_file"
      else
        log "Custom schema import failed; leaving DB in current state"
      fi
    fi
  fi

  # Ensure rivendell waits for DB
  mkdir -p /etc/systemd/system/rivendell.service.d
  cat >/etc/systemd/system/rivendell.service.d/override.conf <<'EOF'
[Unit]
After=network-online.target mariadb.service
Wants=network-online.target mariadb.service
EOF
  systemctl daemon-reload
  systemctl restart rivendell || true
}

firewall_and_ssh() {
  if $enable_ufw; then
    log "Configuring UFW"
    apt_install ufw || true
    ufw allow OpenSSH || true
    ufw allow 3389/tcp || true
    ufw allow 8000/tcp || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw --force enable || true
  fi
  if $harden_ssh; then
    log "Hardening SSH"
    # Skip hardening if no SSH keys present for target_user, rd, or root
    local has_keys=false
    for u in "$target_user" rd root; do
      local ak
      if [[ "$u" == "root" ]]; then
        ak="/root/.ssh/authorized_keys"
      else
        ak="/home/$u/.ssh/authorized_keys"
      fi
      if [[ -s "$ak" ]]; then has_keys=true; break; fi
    done
    if [[ "$has_keys" != true ]]; then
      log "No authorized_keys found. Skipping SSH hardening to prevent lockout."
      return 0
    fi
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
ensure_mariadb
install_local_debs
install_media_apps
install_xrdp_desktop
deploy_apps_payload
configure_icecast
web_meta_file
qt5_xcb_fix
setup_xauth_autolink
suppress_mate_power_manager
firewall_and_ssh
finalize_rivendell_db
pin_rivendell
post_notes

