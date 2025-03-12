#!/bin/bash
set -e  # Exit on error

# Function to prompt user for confirmation
confirm() {
    read -p "$1 (y/n): " REPLY
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
}

# Update and upgrade the system
echo "Updating system..."
sudo apt update && sudo apt dist-upgrade -y

# Set hostname and timezone
echo "Setting hostname and timezone..."
sudo hostnamectl set-hostname onair
sudo timedatectl set-timezone America/Los_Angeles
sudo timedatectl set-ntp yes

# Create 'rd' user and add to sudo group
echo "Creating 'rd' user..."
sudo adduser --gecos "" rd
sudo usermod -aG sudo rd  # Add rd to sudo group

# Install MATE Desktop using tasksel as root
echo "Installing MATE Desktop..."
echo "MATE Desktop must be installed as root. Please switch to root using 'su' and enter the root password."
su -c "tasksel"

# Drop back to the 'rd' user after MATE installation
echo "Switching back to the 'rd' user..."
su rd -c "echo 'Now running as rd user: $(whoami)'"

# Install xRDP
echo "Installing xRDP..."
sudo apt install xrdp dbus-x11 -y

# Set MATE as the default session manager
echo "Setting MATE as the default session manager..."
sudo update-alternatives --config x-session-manager <<< '2'  # Select MATE
sudo update-alternatives --config x-session-manager <<< '0'  # Set to auto mode

# Configure xRDP to use MATE
# echo "Configuring xRDP to use MATE..."
# echo "mate-session" > ~/.xsession
# sudo systemctl restart xrdp

# Install Rivendell
echo "Installing Rivendell..."
wget https://software.paravelsystems.com/ubuntu/dists/jammy/main/install_rivendell.sh
chmod +x install_rivendell.sh
echo "2" | sudo ./install_rivendell.sh  # Automatically select '2' for Server install

# Add Rivendell to audio group
sudo usermod -aG audio rivendell

# Install broadcasting tools (Icecast, JACK, Liquidsoap, VLC)
echo "Installing broadcasting tools..."
sudo apt install -y icecast2 jackd2 qjackctl liquidsoap vlc vlc-plugin-jack gnome-system-monitor

# Configure Icecast
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
    <shoutcast-mount>/stream</shoutcast-mount>
</listen-socket>
EOL

# Enable and start Icecast
echo "Enabling and starting Icecast..."
sudo systemctl daemon-reload
sudo systemctl enable icecast2
sudo systemctl start icecast2
sudo systemctl status icecast2

# Disable PulseAudio and configure audio
echo "Disabling PulseAudio..."
sudo killall pulseaudio || true
sudo sed -i 's/# autospawn = yes/autospawn = no/' /etc/pulse/client.conf
sudo gpasswd -d pulse audio
sudo usermod -aG audio rd rivendell liquidsoap
sudo tee -a /etc/security/limits.conf <<EOL
@audio      hard      rtprio          90
@audio      hard      memlock     unlimited
EOL

# Create directories
echo "Creating directories..."
sudo -u rd mkdir -p /home/rd/imports /home/rd/logs

# Download APPS folder
echo "Downloading APPS folder..."
sudo -u rd git clone https://github.com/anjeleno/Rivendell-Cloud.git /home/rd/Rivendell-Cloud

# Move APPS folder and set permissions
echo "Moving APPS folder and setting permissions..."
APPS_SRC="/home/rd/Rivendell-Cloud/APPS"
APPS_DEST="/home/rd/imports/APPS"
sudo -u rd mv "$APPS_SRC" "$APPS_DEST"
sudo -u rd chmod -R +x "$APPS_DEST"
sudo -u rd chown -R rd:rd "$APPS_DEST"

# Move desktop shortcuts
echo "Moving desktop shortcuts..."
DESKTOP_SHORTCUTS="$APPS_DEST/Desktop Shortcuts"
USER_DESKTOP="/home/rd/Desktop"
sudo -u rd mv "$DESKTOP_SHORTCUTS"/* "$USER_DESKTOP"

# Extract MySQL password from rd.conf
echo "Extracting MySQL password from /etc/rd.conf..."
MYSQL_PASSWORD=$(grep -oP '(?<=Password=).*' /etc/rd.conf)
echo "Using extracted MySQL password."

# Inject MySQL password into backup script
echo "Updating daily_db_backup.sh with MySQL password..."
sudo sed -i "s|Password=.*|Password=$MYSQL_PASSWORD|" "$APPS_DEST/.sql/daily_db_backup.sh"

# Configure cron jobs
echo "Configuring cron jobs..."
(crontab -l 2>/dev/null; echo "05 00 * * * $APPS_DEST/.sql/daily_db_backup.sh >> $APPS_DEST/.sql/cron_execution.log 2>&1") | crontab -
(crontab -l 2>/dev/null; echo "15 00 * * * $APPS_DEST/autologgen.sh") | crontab -

# Enable firewall
echo "Configuring firewall..."
sudo apt install -y ufw

# Prompt user for external IP
echo "Please enter your external IP address to allow in the firewall:"
read -p "External IP: " EXTERNAL_IP

# Apply firewall rules
sudo ufw allow 8000/tcp
sudo ufw allow ssh
sudo ufw allow from "$EXTERNAL_IP"
sudo ufw enable

# Harden SSH access
echo "Hardening SSH access..."
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config-BAK
sudo sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' /etc/ssh/sshd_config
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
sudo systemctl restart ssh

# Fix QT5 XCB error
echo "Fixing QT5 XCB error..."
sudo ln -s /home/rd/.Xauthority /root/.Xauthority

# Prompt user to reboot
confirm "Would you like to reboot now to apply changes?"
echo "Rebooting system..."
sudo reboot