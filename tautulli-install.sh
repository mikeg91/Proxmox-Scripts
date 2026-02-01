#!/bin/bash

###############################################################################
# Tautulli Installation Script for Debian LXC
# This script automates the installation of Tautulli on a Debian-based system
###############################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root (use sudo or run as root user)"
    exit 1
fi

print_message "Starting Tautulli installation..."

# Update system
print_message "Updating system packages..."
apt update && apt upgrade -y

# Install required packages
print_message "Installing dependencies..."
apt install -y python3 python3-pip python3-venv python3-full git curl wget

# Create tautulli user if it doesn't exist
if id "tautulli" &>/dev/null; then
    print_warning "User 'tautulli' already exists, skipping user creation"
else
    print_message "Creating tautulli user..."
    useradd -r -s /bin/bash -d /opt/tautulli -m tautulli
fi

# Clone Tautulli repository
if [ -d "/opt/tautulli/.git" ]; then
    print_warning "Tautulli directory already exists, pulling latest changes..."
    cd /opt/tautulli
    sudo -u tautulli git pull
else
    print_message "Cloning Tautulli repository..."
    if [ -d "/opt/tautulli" ]; then
        rm -rf /opt/tautulli
    fi
    git clone https://github.com/Tautulli/Tautulli.git /opt/tautulli
    chown -R tautulli:tautulli /opt/tautulli
fi

# Create virtual environment
print_message "Creating Python virtual environment..."
if [ -d "/opt/tautulli/venv" ]; then
    print_warning "Virtual environment already exists, recreating..."
    rm -rf /opt/tautulli/venv
fi

sudo -u tautulli python3 -m venv /opt/tautulli/venv

# Install Python dependencies
print_message "Installing Python requirements..."
sudo -u tautulli /opt/tautulli/venv/bin/pip install --upgrade pip
sudo -u tautulli /opt/tautulli/venv/bin/pip install -r /opt/tautulli/requirements.txt

# Create systemd service
print_message "Creating systemd service..."
cat > /etc/systemd/system/tautulli.service << 'EOF'
[Unit]
Description=Tautulli - Stats for Plex Media Server usage
After=network.target

[Service]
Type=simple
User=tautulli
Group=tautulli
WorkingDirectory=/opt/tautulli
ExecStart=/opt/tautulli/venv/bin/python /opt/tautulli/Tautulli.py --datadir /opt/tautulli --quiet --nolaunch
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start service
print_message "Enabling and starting Tautulli service..."
systemctl daemon-reload
systemctl enable tautulli
systemctl start tautulli

# Wait a moment for service to start
sleep 3

# Check service status
if systemctl is-active --quiet tautulli; then
    print_message "Tautulli service is running successfully!"
else
    print_error "Tautulli service failed to start. Check logs with: journalctl -u tautulli -n 50"
    exit 1
fi

# Get IP address
IP_ADDRESS=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Tautulli Installation Complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "Access Tautulli at: ${YELLOW}http://${IP_ADDRESS}:8181${NC}"
echo ""
echo "Useful commands:"
echo "  - Check status:  systemctl status tautulli"
echo "  - View logs:     journalctl -u tautulli -f"
echo "  - Restart:       systemctl restart tautulli"
echo "  - Stop:          systemctl stop tautulli"
echo ""
echo "To update Tautulli in the future:"
echo "  systemctl stop tautulli"
echo "  cd /opt/tautulli && sudo -u tautulli git pull"
echo "  sudo -u tautulli /opt/tautulli/venv/bin/pip install -r requirements.txt"
echo "  systemctl start tautulli"
echo ""
echo -e "${GREEN}================================================${NC}"
