#!/bin/bash
# Rivendell Auto-Install Script
# Version: 0.20.13
# Date: 2025-03-15
# Author: Branjeleno
# Description: This script automates the installation and configuration of Rivendell,
#              MATE Desktop, xRDP, and related broadcasting tools optimized to run
#              on Ubuntu 22.04 in a cloud VPS. It includes everything you need
#              out-of-the-box to stream liquidsoap, icecast and Stere Tool.
#
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

# Ensure the step tracking directory exists and has the correct permissions
ensure_step_dir() {
    if [ ! -d "$STEP_DIR" ]; then
        sudo mkdir -p "$STEP_DIR"
        sudo chown rd:rd "$STEP_DIR"
    fi
}

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
        return 1
    fi
}

# Function to mark a step as completed
mark_step_completed() {
    local step_name="$1"
    touch "$STEP_DIR/$step_name"
}

# Function to ensure the script is running as the 'rd' user
ensure_rd_user() {
    if [ "$(whoami)" != "rd" ]; then
        echo "The script must be run as the 'rd' user. Please switch to the 'rd' user and rerun the script."
        echo "To switch to the 'rd' user, run:"
        echo "  su rd"
        echo "Then rerun the script."
        exit 1
    fi
}

# Update and upgrade the system
system_update() {
    echo "Updating system..."
    sudo apt update && sudo apt dist-upgrade -y
    mark_step_completed "system_update"
}

# Set hostname
set_hostname() {
    echo "Setting hostname..."
    sudo hostnamectl set-hostname onair
    sudo sed -i "/127.0.1.1/c\127.0.1.1\tonair" /etc/hosts
    mark_step_completed "set_hostname"
}

# Set timezone
set_timezone() {
    echo "Setting timezone..."
    echo "Please select your timezone:"
    sudo dpkg-reconfigure tzdata
    sudo timedatectl set-ntp yes
    mark_step_completed "set_timezone"
}

# Create 'rd' user and add to sudo group
create_rd_user() {
    echo "Creating 'rd' user..."
    if ! id -u rd >/dev/null 2>&1; then
        sudo adduser --disabled-password --gecos "rd,Rivendell Audio,,," --home /home/rd rd
        sudo usermod -aG sudo rd
        echo "Please set a password for the 'rd' user:"
        sudo passwd rd
        sudo chown -R rd:rd /home/rd
        sudo chmod 755 /home/rd
        echo "User 'rd' created. Skeleton files copied to /home/rd."
    else
        echo "User 'rd' already exists. Skipping..."
    fi
    mark_step_completed "create_rd_user"
}

copy_working_directory() {
    echo "Copying working directory to /home/rd/Rivendell-Cloud..."
    if [ ! -d "/home/rd/Rivendell-Cloud" ]; then
        sudo cp -r "$(pwd)" /home/rd/Rivendell-Cloud
        sudo chown -R rd:rd /home/rd/Rivendell-Cloud
        echo "Working directory copied successfully."
    else
        echo "Working directory already exists. Skipping copy."
    fi
    mark_step_completed "copy_working_directory"
}

configure_shell_profile() {
    echo "Configuring shell profile to auto-change directory on login..."
    if ! grep -q "cd /home/rd/Rivendell-Cloud" /home/rd/.bashrc; then
        echo "cd /home/rd/Rivendell-Cloud" | sudo tee -a /home/rd/.bashrc > /dev/null
        sudo chown rd:rd /home/rd/.bashrc
        echo "Shell profile configured."
    else
        echo "Shell profile already configured. Skipping."
    fi
    mark_step_completed "configure_shell_profile"
}

prompt_reboot() {
    echo "Reboot is required. Do you want to reboot now? (y/n)"
    read -r answer
    if [ "$answer" != "${answer#[Yy]}" ]; then
        sudo reboot
    else
        echo "Please reboot the system manually to continue."
    fi
}

# Install tasksel if not already installed
install_tasksel() {
    echo "Installing tasksel..."
    sudo apt install tasksel -y
    mark_step_completed "install_tasksel"
}

# Install MATE Desktop using tasksel as root
install_mate() {
    echo "Installing MATE Desktop..."
    echo "MATE Desktop installing as root. On the next screen, use the arrow keys and spacebar to select MATE, OK and enter to continue."
    su -c "tasksel"
    mark_step_completed "install_mate"
}

# Install xRDP
install_xrdp() {
    echo "Installing xRDP..."
    sudo apt install xrdp dbus-x11 -y
    mark_step_completed "install_xrdp"
}

# Configure xRDP to use MATE
configure_xrdp() {
    echo "Configuring xRDP to use MATE..."
    echo "mate-session" | sudo tee /home/rd/.xsession > /dev/null
    sudo chown rd:rd /home/rd/.xsession  # Ensure rd owns the file
    sudo systemctl restart xrdp
    mark_step_completed "configure_xrdp"
}

# Set MATE as the default session manager
set_mate_default() {
    echo "Setting MATE as the default session manager..."
    sudo update-alternatives --config x-session-manager <<< '2'  # Select MATE
    sudo update-alternatives --config x-session-manager <<< '0'  # Set to auto mode
    mark_step_completed "set_mate_default"
}

# Install Rivendell
install_rivendell() {
    echo "Installing Rivendell..."
    wget https://software.paravelsystems.com/ubuntu/dists/jammy/main/install_rivendell.sh || return 1
    chmod +x install_rivendell.sh || return 1
    echo "2" | sudo ./install_rivendell.sh || return 1
    mark_step_completed "install_rivendell"
}

# Create pypad text file for now and next meta to web or external app
touch_pypad() {
    sudo touch /var/www/html/meta.txt
    sudo chown pypad:pypad /var/www/html/meta.txt
    mark_step_completed "touch_pypad"
}

# Install broadcasting tools (Icecast, JACK, Liquidsoap, VLC)
install_broadcasting_tools() {
    echo "Installing broadcasting tools..."
    sudo apt install -y icecast2 jackd2 qjackctl liquidsoap vlc vlc-plugin-jack
    mark_step_completed "install_broadcasting_tools"
}

# Create directories as 'rd' user
create_directories() {
    echo "Creating directories..."
    mkdir -p /home/rd/imports /home/rd/logs
    chown rd:rd /home/rd/imports /home/rd/logs
    mark_step_completed "create_directories"
}

# Move APPS folder and set permissions as 'rd' user
move_apps() {
    echo "Moving APPS folder and setting permissions..."
    APPS_SRC="/home/rd/Rivendell-Cloud/APPS"
    APPS_DEST="/home/rd/imports/APPS"
    mv "$APPS_SRC" "$APPS_DEST"
    chmod -R +x "$APPS_DEST"
    chown -R rd:rd "$APPS_DEST"
    mark_step_completed "move_apps"
}

# Move desktop shortcuts as 'rd' user
move_shortcuts() {
    echo "Moving desktop shortcuts..."
    SHORTCUTS_SRC="/home/rd/imports/APPS/Shortcuts"
    USER_DESKTOP="/home/rd/Desktop"

    # Ensure the Desktop directory exists
    mkdir -p "$USER_DESKTOP"

    if [ -d "$SHORTCUTS_SRC" ]; then
        mv "$SHORTCUTS_SRC"/* "$USER_DESKTOP" || {
            echo "Failed to move desktop shortcuts. Check permissions or if files already exist."
            exit 1
        }
        echo "Desktop shortcuts moved successfully."
    else
        echo "Error: $SHORTCUTS_SRC does not exist. Check if the APPS folder was downloaded correctly."
        exit 1
    fi
    mark_step_completed "move_shortcuts"
}

# Replace default icecast.xml with custom icecast.xml
configure_icecast() {
    echo "Configuring Icecast..."

    # Backup the original icecast.xml
    if [ -f /etc/icecast2/icecast.xml ]; then
        sudo cp /etc/icecast2/icecast.xml /etc/icecast2/icecast.xml.bak
        echo "Backed up original icecast.xml to /etc/icecast2/icecast.xml.bak"
    fi

    # Check if the custom icecast.xml exists
    if [ -f /home/rd/imports/APPS/icecast.xml ]; then
        sudo cp -f /home/rd/imports/APPS/icecast.xml /etc/icecast2/icecast.xml
        sudo chown icecast2:icecast2 /etc/icecast2/icecast.xml
        sudo chmod 640 /etc/icecast2/icecast.xml
        echo "Custom icecast.xml copied successfully."
    else
        echo "Error: /home/rd/imports/APPS/icecast.xml does not exist. Please check the file path."
        exit 1
    fi

    echo "Icecast configuration updated."
    mark_step_completed "configure_icecast"
}

enable_icecast() {
    echo "Enabling and starting Icecast..."

    # Reload systemd and start Icecast
    sudo systemctl daemon-reload
    sudo systemctl enable icecast2
    sudo systemctl start icecast2

    echo "Icecast service enabled and started. Skipping status check to avoid blocking the script."
    mark_step_completed "enable_icecast"
}

# Disable PulseAudio and configure audio
disable_pulseaudio() {
    echo "Disabling PulseAudio..."
    sudo killall pulseaudio || true
    sudo sed -i 's/# autospawn = yes/autospawn = no/' /etc/pulse/client.conf
    sudo gpasswd -d pulse audio || true
    sudo usermod -aG audio rd
    sudo usermod -aG audio rivendell
    sudo usermod -aG audio liquidsoap
    sudo tee -a /etc/security/limits.conf <<EOL
@audio      hard      rtprio          90
@audio      hard      memlock     unlimited
EOL
    mark_step_completed "disable_pulseaudio"
}

# Fix QT5 XCB error
fix_qt5() {
    echo "Fixing QT5 XCB error..."
    sudo ln -s /home/rd/.Xauthority /root/.Xauthority
    mark_step_completed "fix_qt5"
}

# Extract MySQL password and store it in a global variable
extract_mysql_password() {
    echo "Extracting MySQL password from /etc/rd.conf..."
    
    # Extract the MySQL password from the [mySQL] section
    MYSQL_PASSWORD=$(awk -F= '/\[mySQL\]/{flag=1;next}/\[/{flag=0}flag && /Password=/{print $2;exit}' /etc/rd.conf)
    
    # Check if the password was extracted successfully
    if [ -z "$MYSQL_PASSWORD" ]; then
        echo "Error: Failed to extract MySQL password from /etc/rd.conf. Please check the file and ensure the [mySQL] section exists."
        exit 1
    else
        echo "MySQL password extracted successfully: $MYSQL_PASSWORD"
    fi
    mark_step_completed "extract_mysql_password"
}

update_backup_script() {
    echo "Updating daily_db_backup.sh with MySQL password..."
    sed -i "s|SQL_PASSWORD_GOES_HERE|${MYSQL_PASSWORD}|" /home/rd/imports/APPS/.sql/daily_db_backup.sh
    sed -i 's/ -p /-p/' /home/rd/imports/APPS/.sql/daily_db_backup.sh
    echo "Backup script updated successfully."
    mark_step_completed "update_backup_script"
}

# Configure cron jobs
configure_cron() {
    echo "Configuring cron jobs..."
    (crontab -l 2>/dev/null; echo "05 00 * * * /home/rd/imports/APPS/.sql/daily_db_backup.sh >> /home/rd/imports/APPS/.sql/cron_execution.log 2>&1") | crontab -
    (crontab -l 2>/dev/null; echo "15 00 * * * /home/rd/imports/APPS/autologgen.sh") | crontab -
    mark_step_completed "configure_cron"
}

# Enable firewall
enable_firewall() {
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
    mark_step_completed "enable_firewall"
}

# Harden SSH access
harden_ssh() {
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
    mark_step_completed "harden_ssh"
}

# Prompt user to reboot
final_reboot() {
    confirm "Would you like to reboot now to apply changes?"
    mark_step_completed "final_reboot"
    echo "Rebooting system..."
    sudo reboot
}

# Main script execution after reboot as 'rd' user
ensure_rd_user

if ! step_completed "set_timezone"; then set_timezone; fi
if ! step_completed "install_tasksel"; then install_tasksel; fi
if ! step_completed "install_mate"; then install_mate; fi
if ! step_completed "install_xrdp"; then install_xrdp; fi
if ! step_completed "configure_xrdp"; then configure_xrdp; fi
if ! step_completed "set_mate_default"; then set_mate_default; fi
if ! step_completed "install_rivendell"; then install_rivendell; fi
if ! step_completed "install_broadcasting_tools"; then install_broadcasting_tools; fi
if ! step_completed "create_directories"; then create_directories; fi
if ! step_completed "move_apps"; then move_apps; fi
if ! step_completed "move_shortcuts"; then move_shortcuts; fi
if ! step_completed "configure_icecast"; then configure_icecast; fi
if ! step_completed "enable_icecast"; then enable_icecast; fi
if ! step_completed "disable_pulseaudio"; then disable_pulseaudio; fi
if ! step_completed "fix_qt5"; then fix_qt5; fi
if ! step_completed "extract_mysql_password"; then extract_mysql_password; fi
if ! step_completed "update_backup_script"; then update_backup_script; fi
if ! step_completed "configure_cron"; then configure_cron; fi
if ! step_completed "enable_firewall"; then enable_firewall; fi
if ! step_completed "harden_ssh"; then harden_ssh; fi
if ! step_completed "final_reboot"; then final_reboot; fi