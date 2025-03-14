#!/bin/bash
# Rivendell Auto-Install Script
# Version: 0.17.3
# Date: 2025-03-14
# Author: Your Name
# Description: This script automates the installation and configuration of Rivendell,
#              MATE Desktop, xRDP, and related broadcasting tools on Ubuntu.
#              It includes step tracking to allow resuming after reboots and
#              handles mid-script reboots gracefully.
# Usage: Run as your default user. Ensure you have sudo privileges.
#        After a reboot, rerun the script as the 'rd' user to resume installation.
#        
#        cd Rivendell-Cloud
#        chmod +x Rivendell-auto-install.sh
#        sudo ./Rivendell-auto-install.sh
#        Reboot when prompted
#        cd Rivendell-Cloud
#        su rd (enter the password you set)
#        ./Rivendell-auto-install.sh
#        Enter the password you set for rd if prompted

set -e  # Exit on error
set -x  # Enable debugging

# Persistent step tracking directory
STEP_DIR="/home/rd/rivendell_install_steps"

# Function to prompt user for confirmation
confirm() {
    read -p "$1 (y/n): " REPLY
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
}

# Function to check if a step has already been completed
step_completed() {
    local step_name="$1"
    if [ -f "$STEP_DIR/$step_name" ]; then
        echo "Step '$step_name' already completed. Skipping..."
        return 0
    else
        echo "Running step '$step_name'..."
        # Execute the step (passed as arguments to the function)
        if "${@:2}"; then
            # Mark the step as completed if it succeeds
            touch "$STEP_DIR/$step_name"
            return 0
        else
            echo "Step '$step_name' failed. Please troubleshoot and rerun the script."
            exit 1
        fi
    fi
}

# Function to handle mid-script reboots
mid_script_reboot() {
    local step_name="$1"
    echo "Marking step '$step_name' as completed..."
    touch "$STEP_DIR/$step_name"
    echo "A reboot is required to proceed. Please reboot the system and rerun the script as the 'rd' user."
    confirm "Reboot now?"
    echo "Rebooting system..."
    sudo reboot
}

# Ensure the step tracking directory exists and is owned by 'rd'
ensure_step_dir() {
    if [ ! -d "$STEP_DIR" ]; then
        sudo mkdir -p "$STEP_DIR"
        sudo chown rd:rd "$STEP_DIR"
    fi
}

# Create 'rd' user and add to sudo group
create_rd_user() {
    step_completed create_rd_user || return 0
    echo "Creating 'rd' user..."
    if ! id -u rd >/dev/null 2>&1; then
        # Create the 'rd' user with the correct full name and home directory
        sudo adduser --disabled-password --gecos "rd,Rivendell Audio,,," --home /home/rd rd
        sudo usermod -aG sudo rd  # Add rd to sudo group

        # Set a password for the 'rd' user
        echo "Please set a password for the 'rd' user:"
        sudo passwd rd

        # Ensure the home directory is owned by 'rd' and has correct permissions
        sudo chown -R rd:rd /home/rd
        sudo chmod 755 /home/rd

        echo "User 'rd' created. Skeleton files copied to /home/rd."

        # Create the step tracking directory after the 'rd' user is created
        ensure_step_dir
    else
        echo "User 'rd' already exists. Skipping..."
    fi
}

# Update and upgrade the system
system_update() {
    step_completed system_update || return 0
    echo "Updating system..."
    sudo apt update && sudo apt dist-upgrade -y
}

# Set hostname and timezone
hostname_timezone() {
    step_completed hostname_timezone || return 0
    echo "Setting hostname and timezone..."

    # Set hostname
    sudo hostnamectl set-hostname onair
    sudo sed -i "/127.0.1.1/c\127.0.1.1\tonair" /etc/hosts

    # Interactive timezone selection
    echo "Please select your timezone:"
    sudo dpkg-reconfigure tzdata

    # Enable NTP
    sudo timedatectl set-ntp yes
}

# Install tasksel if not already installed
install_tasksel() {
    step_completed install_tasksel || return 0
    echo "Installing tasksel..."
    sudo apt install tasksel -y
}

# Install MATE Desktop using tasksel as root
install_mate() {
    step_completed install_mate || return 0
    echo "Installing MATE Desktop..."
    echo "MATE Desktop must be installed as root. Please enter the root password when prompted."
    su -c "tasksel"
}

# Install xRDP
install_xrdp() {
    step_completed install_xrdp || return 0
    echo "Installing xRDP..."
    sudo apt install xrdp dbus-x11 -y
}

# Configure xRDP to use MATE
configure_xrdp() {
    step_completed configure_xrdp || return 0
    echo "Configuring xRDP to use MATE..."
    echo "mate-session" | sudo tee /home/rd/.xsession > /dev/null
    sudo chown rd:rd /home/rd/.xsession  # Ensure rd owns the file
    sudo systemctl restart xrdp
}

# Set MATE as the default session manager
set_mate_default() {
    step_completed set_mate_default || return 0
    echo "Setting MATE as the default session manager..."
    sudo update-alternatives --config x-session-manager <<< '2'  # Select MATE
    sudo update-alternatives --config x-session-manager <<< '0'  # Set to auto mode

    # Reboot here to ensure MATE is fully configured before proceeding
    mid_script_reboot set_mate_default
}

# Fix QT5 XCB error
fix_qt5() {
    step_completed fix_qt5 || return 0
    echo "Fixing QT5 XCB error..."
    sudo ln -s /home/rd/.Xauthority /root/.Xauthority
}

# Install Rivendell
install_rivendell() {
    step_completed install_rivendell || return 0
    echo "Installing Rivendell..."
    wget https://software.paravelsystems.com/ubuntu/dists/jammy/main/install_rivendell.sh || return 1
    chmod +x install_rivendell.sh || return 1
    echo "2" | sudo ./install_rivendell.sh || return 1
}

# Install broadcasting tools (Icecast, JACK, Liquidsoap, VLC)
install_broadcasting_tools() {
    step_completed install_broadcasting_tools || return 0
    echo "Installing broadcasting tools..."
    sudo apt install -y icecast2 jackd2 qjackctl liquidsoap vlc vlc-plugin-jack gnome-system-monitor
}

# Configure Icecast
configure_icecast() {
    step_completed configure_icecast || return 0
    echo "Configuring Icecast..."
    sudo cp /etc/icecast2/icecast.xml /etc/icecast2/icecast.xml-backup

    # Replace the authentication and listen-socket sections
    sudo sed -i '/<authentication>/,/<\/authentication>/d' /etc/icecast2/icecast.xml
    sudo sed -i '/<listen-socket>/,/<\/listen-socket>/d' /etc/icecast2/icecast.xml

    sudo tee -a /etc/icecast2/icecast.xml <<EOL
<authentication>
    <source-password>hackm3</source-password>
    <relay-password>hackm33</relay-password>
    <admin-user>admin</admin-user>
    <admin-password>Hackm333</admin-password>
</authentication>

<listen-socket>
    <port>8000</port>
    <shoutcast-mount>/192</shoutcast-mount>
    <shoutcast-mount>/stream</shoutcast-mount>
</listen-socket>
EOL

    echo "Icecast configuration updated."
}

# Enable and start Icecast (without blocking the script)
enable_icecast() {
    step_completed enable_icecast || return 0
    echo "Enabling and starting Icecast..."
    sudo systemctl daemon-reload
    sudo systemctl enable icecast2
    sudo systemctl start icecast2
    echo "Icecast service enabled and started. Skipping status check to avoid blocking the script."
}

# Disable PulseAudio and configure audio
disable_pulseaudio() {
    step_completed disable_pulseaudio || return 0
    echo "Disabling PulseAudio..."
    sudo killall pulseaudio || true
    sudo sed -i 's/# autospawn = yes/autospawn = no/' /etc/pulse/client.conf
    sudo gpasswd -d pulse audio
    sudo usermod -aG audio rd rivendell liquidsoap
    sudo tee -a /etc/security/limits.conf <<EOL
@audio      hard      rtprio          90
@audio      hard      memlock     unlimited
EOL
}

# Create directories as 'rd' user
create_directories() {
    step_completed create_directories || return 0
    echo "Creating directories..."
    mkdir -p /home/rd/imports /home/rd/logs
    chown rd:rd /home/rd/imports /home/rd/logs
}

# Download APPS folder as 'rd' user
download_apps() {
    step_completed download_apps || return 0
    echo "Downloading APPS folder..."
    git clone https://github.com/anjeleno/Rivendell-Cloud.git /home/rd/Rivendell-Cloud
}

# Move APPS folder and set permissions as 'rd' user
move_apps() {
    step_completed move_apps || return 0
    echo "Moving APPS folder and setting permissions..."
    APPS_SRC="/home/rd/Rivendell-Cloud/APPS"
    APPS_DEST="/home/rd/imports/APPS"
    mv "$APPS_SRC" "$APPS_DEST"
    chmod -R +x "$APPS_DEST"
    chown -R rd:rd "$APPS_DEST"
}

# Move desktop shortcuts as 'rd' user
move_shortcuts() {
    step_completed move_shortcuts || return 0
    echo "Moving desktop shortcuts..."
    DESKTOP_SHORTCUTS="$APPS_DEST/Shortcuts"
    USER_DESKTOP="/home/rd/Desktop"

    if [ -d "$DESKTOP_SHORTCUTS" ]; then
        if [ -d "$USER_DESKTOP" ]; then
            mv "$DESKTOP_SHORTCUTS"/* "$USER_DESKTOP" || {
                echo "Failed to move desktop shortcuts. Check permissions or if files already exist."
                exit 1
            }
            echo "Desktop shortcuts moved successfully."
        else
            echo "Error: $USER_DESKTOP does not exist. Ensure the Desktop directory is created."
            exit 1
        fi
    else
        echo "Error: $DESKTOP_SHORTCUTS does not exist. Check if the APPS folder was downloaded correctly."
        exit 1
    fi
}

# Extract MySQL password from rd.conf
extract_mysql_password() {
    step_completed extract_mysql_password || return 0
    echo "Extracting MySQL password from /etc/rd.conf..."
    MYSQL_PASSWORD=$(grep -oP '(?<=Password=).*' /etc/rd.conf)
    echo "Using extracted MySQL password."
}

# Inject MySQL password into backup script
update_backup_script() {
    step_completed update_backup_script || return 0
    echo "Updating daily_db_backup.sh with MySQL password..."
    sed -i "s|Password=.*|Password=$MYSQL_PASSWORD|" "$APPS_DEST/.sql/daily_db_backup.sh"
}

# Configure cron jobs
configure_cron() {
    step_completed configure_cron || return 0
    echo "Configuring cron jobs..."
    (crontab -l 2>/dev/null; echo "05 00 * * * /home/rd/imports/APPS/.sql/daily_db_backup.sh >> /home/rd/imports/APPS/.sql/cron_execution.log 2>&1") | crontab -
    (crontab -l 2>/dev/null; echo "15 00 * * * /home/rd/imports/APPS/autologgen.sh") | crontab -
}

# Enable firewall
enable_firewall() {
    step_completed enable_firewall || return 0
    echo "Configuring firewall..."
    sudo apt install -y ufw

    # Prompt user for external IP
    echo "Please enter your external IP address to allow in the firewall:"
    read -p "External IP: " EXTERNAL_IP

    # Prompt user for LAN subnet (e.g., 192.168.1.0/24)
    echo "Please enter your LAN subnet (e.g., 192.168.1.0/24):"
    read -p "LAN Subnet: " LAN_SUBNET

    # Apply firewall rules
    sudo ufw allow 8000/tcp
    sudo ufw allow ssh
    sudo ufw allow from "$EXTERNAL_IP"
    if [ -n "$LAN_SUBNET" ]; then
        sudo ufw allow from "$LAN_SUBNET"
    fi
    sudo ufw enable
}

# Harden SSH access
harden_ssh() {
    step_completed harden_ssh || return 0
    echo "Hardening SSH access..."
    echo "WARNING: This will disable password authentication and allow only SSH key-based login."
    echo "Ensure you have added your SSH public key to ~/.ssh/authorized_keys and confirmed you can log in with it."
    confirm "Have you confirmed SSH key-based login works and want to proceed with hardening SSH?"

    # Backup SSH config files
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config-BAK
    sudo cp /etc/ssh/sshd_config.d/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf-BAK

    # Disable password authentication in sshd_config
    sudo sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' /etc/ssh/sshd_config
    sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config

    # Disable password authentication in 50-cloud-init.conf
    sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config.d/50-cloud-init.conf

    sudo systemctl restart ssh
    echo "SSH access has been hardened. Password authentication is now disabled."
}

# Prompt user to reboot
final_reboot() {
    step_completed final_reboot || return 0
    confirm "Would you like to reboot now to apply changes?"
    echo "Rebooting system..."
    sudo reboot
}

# Main script execution
create_rd_user  # Ensure the 'rd' user is created first
ensure_step_dir  # Now we can safely create the step directory
system_update
hostname_timezone
install_tasksel
install_mate
install_xrdp
configure_xrdp
set_mate_default  # Reboot happens here after setting MATE as default
fix_qt5  # QT5 fix happens after reboot

# Ensure the script is running as the 'rd' user before installing Rivendell
if [ "$(whoami)" != "rd" ]; then
    echo "Please switch to the 'rd' user and rerun the script to continue installation."
    echo "To switch to the 'rd' user, run:"
    echo "  su rd"
    echo "Then rerun the script."
    exit 1
fi

# Install Rivendell and broadcasting tools
install_rivendell
install_broadcasting_tools
configure_icecast
enable_icecast
disable_pulseaudio
create_directories
download_apps
move_apps
move_shortcuts
extract_mysql_password
update_backup_script
configure_cron
enable_firewall
harden_ssh
final_reboot