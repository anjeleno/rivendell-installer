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

# Install MATE Desktop
# echo "Installing MATE Desktop..."
# sudo apt install tasksel -y
# sudo tasksel install ubuntu-mate

# Check if the script is being run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "You are not running as root. Switching to root using 'su'."
    # Prompt the user to enter their root password for elevation
    su -c "tasksel install mate-desktop"
    exit 0
fi

# If already root, run tasksel to install MATE
echo "Running tasksel to install MATE..."
tasksel install mate-desktop

# Confirm installation
echo "MATE desktop installation is complete."

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
sudo -u rd git clone https://github.com/anjeleno/Rivendell-Cloud.git /home/rd/imports/APPS

# Move APPS and Shortcuts and make executable
# Define the paths
CLONED_DIR="/home/rd/Rivendell-Cloud/"  # Path where APPS is initially located
APPS_DIR="$CLONED_DIR/APPS"  # Source APPS folder
DEST_PARENT_DIR="/home/rd/imports"  # Destination parent directory
DEST_DIR="$DEST_PARENT_DIR/APPS"  # Where APPS should end up
DESKTOP_SHORTCUTS_DIR="$DEST_DIR/Desktop Shortcuts"  # Corrected path after moving
USER_DESKTOP="/home/rd/Desktop"  # Assuming user 'rd'

# Ensure the destination parent directory exists
mkdir -p "$DEST_PARENT_DIR"

# Check if the APPS directory exists in the source location
if [ -d "$APPS_DIR" ]; then
    echo "Found APPS directory: $APPS_DIR"
    
    # Remove existing APPS folder at destination to prevent duplication
    if [ -d "$DEST_DIR" ]; then
        echo "Removing existing APPS directory at $DEST_DIR to prevent nesting..."
        rm -rf "$DEST_DIR"
    fi

    # Move APPS to the correct location
    echo "Moving APPS folder to $DEST_PARENT_DIR..."
    mv "$APPS_DIR" "$DEST_PARENT_DIR"
    
    # Check if the move was successful
    if [ $? -eq 0 ]; then
        echo "APPS folder successfully moved to $DEST_DIR."
    else
        echo "Failed to move APPS folder."
        exit 1
    fi

    # Fix ownership to ensure files belong to 'rd' instead of root
    echo "Changing ownership of $DEST_DIR to rd..."
    chown -R rd:rd "$DEST_DIR"

    # Change file permissions to make everything executable inside APPS
    echo "Changing file permissions in $DEST_DIR..."
    chmod -R +x "$DEST_DIR"

    # Check if the 'Desktop Shortcuts' directory exists in the new location
    if [ -d "$DESKTOP_SHORTCUTS_DIR" ]; then
        echo "Found Desktop Shortcuts directory in $DEST_DIR."

        # Move desktop shortcuts to the user's Desktop
        echo "Moving desktop shortcuts to $USER_DESKTOP..."
        mv "$DESKTOP_SHORTCUTS_DIR"/* "$USER_DESKTOP"

        # Check if the move was successful
        if [ $? -eq 0 ]; then
            echo "Desktop shortcuts successfully moved to the Desktop."
        else
            echo "Failed to move desktop shortcuts."
            exit 1
        fi
    else
        echo "Desktop Shortcuts directory not found inside $DEST_DIR."
        exit 1
    fi

else
    echo "APPS directory not found in $CLONED_DIR."
    exit 1
fi

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
