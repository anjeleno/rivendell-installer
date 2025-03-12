#!/bin/bash
set -e  # Exit on error

# Update and upgrade the system
echo "Updating system..."
sudo apt update && sudo apt dist-upgrade -y

# Set hostname and timezone
echo "Setting hostname and timezone..."
sudo hostnamectl set-hostname onair
sudo timedatectl set-timezone America/Los_Angeles
sudo timedatectl set-ntp yes

# Create 'rd' user and add to rivendell group
echo "Creating 'rd' user..."
sudo adduser --gecos "" rd
sudo usermod -aG rivendell rd

# Install MATE Desktop
echo "Installing MATE Desktop..."
sudo apt install tasksel -y
sudo tasksel install ubuntu-mate

# Install xRDP
echo "Installing xRDP..."
sudo apt install xrdp dbus-x11 -y

echo "You need to manually select MATE as the default session manager."
echo "When prompted, choose the option corresponding to '/usr/bin/mate-session'."
read -p "Press ENTER to continue to selection..."
sudo update-alternatives --config x-session-manager

echo "Now setting MATE to auto mode (option 0)..."
echo "0" | sudo update-alternatives --config x-session-manager

# Install Rivendell
echo "Installing Rivendell..."
wget https://software.paravelsystems.com/ubuntu/dists/jammy/main/install_rivendell.sh
chmod +x install_rivendell.sh
echo "2" | sudo ./install_rivendell.sh  # Automatically select '2' for Server install

# Install Icecast, JACK, Liquidsoap, VLC
echo "Installing broadcasting tools..."
sudo apt install -y icecast2 jackd2 qjackctl liquidsoap vlc vlc-plugin-jack gnome-system-monitor

# Configure Icecast
echo "Configuring Icecast..."
sudo cp /etc/icecast2/icecast.xml /etc/icecast2/icecast.xml-default
sudo tee /etc/icecast2/icecast.xml <<EOL
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
sudo systemctl enable icecast2 --now

# Kill PulseAudio and configure audio
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
sudo -u rd git clone https://github.com/YOUR_GITHUB_USERNAME/APPS.git /home/rd/imports/APPS
chmod -R +x /home/rd/imports/APPS

# Move desktop shortcuts
echo "Setting up desktop shortcuts..."
sudo -u rd mkdir -p /home/rd/Desktop
sudo -u rd chmod +x /home/rd/imports/APPS/Desktop\ Shortcuts/*
sudo -u rd mv /home/rd/imports/APPS/Desktop\ Shortcuts/* /home/rd/Desktop/

# Make .sql backup script executable
echo "Setting up SQL backup scripts..."
sudo -u rd chmod +x /home/rd/imports/APPS/.sql/daily_db_backup.sh

# Extract MySQL password from rd.conf
echo "Extracting MySQL password from /etc/rd.conf..."
MYSQL_PASSWORD=$(grep -oP '(?<=Password=).*' /etc/rd.conf)
echo "Using extracted MySQL password."

# Inject MySQL password into backup script
echo "Updating daily_db_backup.sh with MySQL password..."
sudo sed -i "s|Password=.*|Password=$MYSQL_PASSWORD|" /home/rd/imports/APPS/.sql/daily_db_backup.sh

# Configure cron jobs
echo "Configuring cron jobs..."
(crontab -l 2>/dev/null; echo "05 00 * * * /home/rd/imports/APPS/.sql/daily_db_backup.sh >> /home/rd/imports/APPS/.sql/cron_execution.log 2>&1") | crontab -
(crontab -l 2>/dev/null; echo "15 00 * * * /home/rd/imports/APPS/autologgen.sh") | crontab -

# Enable firewall
echo "Configuring firewall..."
sudo apt install -y ufw

# Prompt user for external IP
echo "Please enter your external IP address to allow in the firewall:"
read -p "External IP: " EXTERNAL_IP

# Apply firewall rules
sudo ufw allow 8000/tcp
sudo ufw allow ssh
sudo ufw allow from $EXTERNAL_IP
sudo ufw enable

# Fix QT5 XCB error
echo "Fixing QT5 XCB error..."
sudo ln -s /home/rd/.Xauthority /root/.Xauthority

# Reboot to apply changes
echo "Rebooting system..."
sudo reboot
