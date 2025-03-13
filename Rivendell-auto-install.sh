#!/bin/bash
set -e  # Exit on error

# Persistent step tracking directory
STEP_DIR="/home/rd/rivendell_install_steps"
sudo mkdir -p "$STEP_DIR"
sudo chown rd:rd "$STEP_DIR"  # Ensure rd owns the step tracking directory

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
        touch "$STEP_DIR/$step_name"
        return 1
    fi
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
if ! step_completed "system_update"; then
    echo "Updating system..."
    sudo apt update && sudo apt dist-upgrade -y
fi

# Set hostname and timezone
if ! step_completed "hostname_timezone"; then
    echo "Setting hostname and timezone..."

    # Set hostname
    sudo hostnamectl set-hostname onair
    sudo sed -i "/127.0.1.1/c\127.0.1.1\tonair" /etc/hosts

    # Interactive timezone selection
    echo "Please select your timezone:"
    sudo dpkg-reconfigure tzdata

    # Enable NTP
    sudo timedatectl set-ntp yes
fi

# Create 'rd' user and add to sudo group
if ! step_completed "create_rd_user"; then
    echo "Creating 'rd' user..."
    if ! id -u rd >/dev/null 2>&1; then
        # Create the 'rd' user with a home directory and proper permissions
        sudo adduser --gecos "Rivendell Audio,,," --home /home/rd rd
        sudo usermod -aG sudo rd  # Add rd to sudo group

        # Ensure the home directory is owned by 'rd' and has correct permissions
        sudo chown -R rd:rd /home/rd
        sudo chmod 755 /home/rd

        echo "User 'rd' created. Skeleton files copied to /home/rd."
    else
        echo "User 'rd' already exists. Skipping..."
    fi
fi

# Install tasksel if not already installed
if ! step_completed "install_tasksel"; then
    echo "Installing tasksel..."
    sudo apt install tasksel -y
fi

# Install MATE Desktop using tasksel as root
if ! step_completed "install_mate"; then
    echo "Installing MATE Desktop..."
    echo "MATE Desktop must be installed as root. Please enter the root password when prompted."
    su -c "tasksel"
fi

# After installing MATE, fall back to the current user (not necessarily rd)
if ! step_completed "switch_to_current_user"; then
    echo "MATE Desktop installation complete. Falling back to the current user: $(whoami)."
    echo "Please log in as the 'rd' user to continue the installation."
    echo "To switch to the 'rd' user, run:"
    echo "  su rd"
    echo "Then rerun the script."
    exit 0
fi

# Ensure the script is running as the 'rd' user before proceeding
ensure_rd_user

# Install xRDP
if ! step_completed "install_xrdp"; then
    echo "Installing xRDP..."
    sudo apt install xrdp dbus-x11 -y
fi

# Configure xRDP to use MATE
if ! step_completed "configure_xrdp"; then
    echo "Configuring xRDP to use MATE..."
    echo "mate-session" | sudo tee /home/rd/.xsession > /dev/null
    sudo chown rd:rd /home/rd/.xsession  # Ensure rd owns the file
    sudo systemctl restart xrdp
fi

# Set MATE as the default session manager
if ! step_completed "set_mate_default"; then
    echo "Setting MATE as the default session manager..."
    sudo update-alternatives --config x-session-manager <<< '2'  # Select MATE
    sudo update-alternatives --config x-session-manager <<< '0'  # Set to auto mode
fi

# Prompt user to reboot before continuing
if ! step_completed "reboot_before_rivendell"; then
    echo "A newer kernel is available. You must reboot to load the new kernel before continuing."
    confirm "Would you like to reboot now?"
    echo "Rebooting system..."
    sudo reboot
fi

# Ensure the script is running as the 'rd' user before installing Rivendell
ensure_rd_user

# Install Rivendell
if ! step_completed "install_rivendell"; then
    echo "Installing Rivendell..."
    wget https://software.paravelsystems.com/ubuntu/dists/jammy/main/install_rivendell.sh
    chmod +x install_rivendell.sh
    echo "2" | sudo ./install_rivendell.sh  # Automatically select '2' for Server install
fi

# Install broadcasting tools (Icecast, JACK, Liquidsoap, VLC)
if ! step_completed "install_broadcasting_tools"; then
    echo "Installing broadcasting tools..."
    sudo apt install -y icecast2 jackd2 qjackctl liquidsoap vlc vlc-plugin-jack gnome-system-monitor
fi

# Configure Icecast
if ! step_completed "configure_icecast"; then
    echo "Configuring Icecast..."
    sudo cp /etc/icecast2/icecast.xml /etc/icecast2/icecast.xml-backup
    sudo tee -a /etc/icecast2/icecast.xml <<EOL
<authentication>
    <source-password>hackme$</source-password>
    <relay-password>hackme$$</relay-password>
    <admin-user>admin</admin-user>
    <admin-password>Hackme$$$</admin-password>
</authentication>

<listen-socket>
    <port>8000</port>
    <shoutcast-mount>/192</shoutcast-mount>
    <shoutcast-mount>/stream</shoutcast-mount>
</listen-socket>
EOL
fi

# Enable and start Icecast (without blocking the script)
if ! step_completed "enable_icecast"; then
    echo "Enabling and starting Icecast..."
    sudo systemctl daemon-reload
    sudo systemctl enable icecast2
    sudo systemctl start icecast2
    echo "Icecast service enabled and started. Skipping status check to avoid blocking the script."
fi

# Disable PulseAudio and configure audio
if ! step_completed "disable_pulseaudio"; then
    echo "Disabling PulseAudio..."
    sudo killall pulseaudio || true
    sudo sed -i 's/# autospawn = yes/autospawn = no/' /etc/pulse/client.conf
    sudo gpasswd -d pulse audio
    sudo usermod -aG audio rd rivendell liquidsoap
    sudo tee -a /etc/security/limits.conf <<EOL
@audio      hard      rtprio          90
@audio      hard      memlock     unlimited
EOL
fi

# Create directories as 'rd' user
if ! step_completed "create_directories"; then
    echo "Creating directories..."
    mkdir -p /home/rd/imports /home/rd/logs
    chown rd:rd /home/rd/imports /home/rd/logs
fi

# Download APPS folder as 'rd' user
if ! step_completed "download_apps"; then
    echo "Downloading APPS folder..."
    git clone https://github.com/anjeleno/Rivendell-Cloud.git /home/rd/Rivendell-Cloud
fi

# Move APPS folder and set permissions as 'rd' user
if ! step_completed "move_apps"; then
    echo "Moving APPS folder and setting permissions..."
    APPS_SRC="/home/rd/Rivendell-Cloud/APPS"
    APPS_DEST="/home/rd/imports/APPS"
    mv "$APPS_SRC" "$APPS_DEST"
    chmod -R +x "$APPS_DEST"
    chown -R rd:rd "$APPS_DEST"
fi

# Move desktop shortcuts as 'rd' user
if ! step_completed "move_shortcuts"; then
    echo "Moving desktop shortcuts..."
    DESKTOP_SHORTCUTS="$APPS_DEST/Desktop Shortcuts"
    USER_DESKTOP="/home/rd/Desktop"
    mv "$DESKTOP_SHORTCUTS"/* "$USER_DESKTOP"
fi

# Fix QT5 XCB error
if ! step_completed "fix_qt5"; then
    echo "Fixing QT5 XCB error..."
    sudo ln -s /home/rd/.Xauthority /root/.Xauthority
fi

# Extract MySQL password from rd.conf
if ! step_completed "extract_mysql_password"; then
    echo "Extracting MySQL password from /etc/rd.conf..."
    MYSQL_PASSWORD=$(grep -oP '(?<=Password=).*' /etc/rd.conf)
    echo "Using extracted MySQL password."
fi

# Inject MySQL password into backup script
if ! step_completed "update_backup_script"; then
    echo "Updating daily_db_backup.sh with MySQL password..."
    sed -i "s|Password=.*|Password=$MYSQL_PASSWORD|" "$APPS_DEST/.sql/daily_db_backup.sh"
fi

# Configure cron jobs
if ! step_completed "configure_cron"; then
    echo "Configuring cron jobs..."
    (crontab -l 2>/dev/null; echo "05 00 * * * /home/rd/imports/APPS/.sql/daily_db_backup.sh >> /home/rd/imports/APPS/.sql/cron_execution.log 2>&1") | crontab -
    (crontab -l 2>/dev/null; echo "15 00 * * * /home/rd/imports/APPS/autologgen.sh") | crontab -
fi

# Enable firewall
if ! step_completed "enable_firewall"; then
    echo "Configuring firewall..."
    sudo apt install -y ufw

    # Prompt user for external IP
    echo "Please enter your external IP address to allow in the firewall:"
    read -p "External IP: " EXTERNAL_IP

    # Prompt user for LAN IP (for local VM environments)
    echo "Please enter your LAN IP address (if applicable, otherwise press Enter):"
    read -p "LAN IP: " LAN_IP

    # Apply firewall rules
    sudo ufw allow 8000/tcp
    sudo ufw allow ssh
    sudo ufw allow from "$EXTERNAL_IP"
    if [ -n "$LAN_IP" ]; then
        sudo ufw allow from "$LAN_IP"
    fi
    sudo ufw enable
fi

# Harden SSH access
if ! step_completed "harden_ssh"; then
    echo "Hardening SSH access..."
    echo "WARNING: This will disable password authentication and allow only SSH key-based login."
    echo "Ensure you have added your SSH public key to ~/.ssh/authorized_keys and confirmed you can log in with it."
    confirm "Have you confirmed SSH key-based login works and want to proceed with hardening SSH?"
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config-BAK
    sudo sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' /etc/ssh/sshd_config
    sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
    sudo systemctl restart ssh
    echo "SSH access has been hardened. Password authentication is now disabled."
fi

# Prompt user to reboot
if ! step_completed "final_reboot"; then
    confirm "Would you like to reboot now to apply changes?"
    echo "Rebooting system..."
    sudo reboot
fi
