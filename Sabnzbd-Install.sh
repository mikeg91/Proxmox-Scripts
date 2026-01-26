#!/usr/bin/env bash
#
# SABnzbd Installation Script for Debian 12 (Bookworm)
# This script installs SABnzbd from Debian Backports and configures it as a systemd service
#
# Usage: Run as root in your Debian/Proxmox LXC container
#   chmod +x install_sabnzbd.sh
#   ./install_sabnzbd.sh
#

# Exit on any error, undefined variables, and pipe failures
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

print_info "Starting SABnzbd installation process..."

# ============================================================================
# STEP 1: Check and install prerequisites
# ============================================================================
print_info "Checking for required packages (curl and gnupg)..."

MISSING_PACKAGES=()

# Check if curl is installed
if ! command -v curl &> /dev/null; then
    print_warning "curl is not installed"
    MISSING_PACKAGES+=("curl")
fi

# Check if gnupg is installed
if ! command -v gpg &> /dev/null; then
    print_warning "gnupg is not installed"
    MISSING_PACKAGES+=("gnupg")
fi

# Install missing packages if any
if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    print_info "Installing missing prerequisites: ${MISSING_PACKAGES[*]}"
    apt update -qq
    apt install -y "${MISSING_PACKAGES[@]}"
    print_info "Prerequisites installed successfully"
else
    print_info "All prerequisites are already installed"
fi

# ============================================================================
# STEP 2: Configure APT sources with Debian Backports
# ============================================================================
print_info "Configuring APT sources with main, contrib, non-free, and backports..."

# Backup existing sources.list
if [ -f /etc/apt/sources.list ]; then
    cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d_%H%M%S)
    print_info "Backed up existing sources.list"
fi

# Write new sources.list with all required repositories including backports
cat <<'EOF' > /etc/apt/sources.list
# Debian Bookworm Main Repositories
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware

# Security Updates
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware

# Stable Updates
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware

# Debian Backports - provides newer versions of select packages
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
EOF

print_info "APT sources configured successfully"

# ============================================================================
# STEP 3: Update package lists and upgrade system
# ============================================================================
print_info "Updating package lists..."
apt update

print_info "Upgrading existing packages (this may take a few minutes)..."
apt upgrade -y

# ============================================================================
# STEP 4: Create sabnzbd user and directories BEFORE installation
# ============================================================================
print_info "Creating sabnzbd user and directory structure..."

# Create the sabnzbd system user if it doesn't already exist
# This is done BEFORE package installation to ensure proper setup
if ! id "sabnzbd" &>/dev/null; then
    print_info "Creating sabnzbd system user..."
    useradd --system --shell /bin/false --no-create-home sabnzbd
    print_info "User 'sabnzbd' created"
else
    print_info "User 'sabnzbd' already exists"
fi

# Create home directory structure for sabnzbd user
# SABnzbd looks for config in the user's home directory by default
print_info "Creating home directory for sabnzbd user..."
mkdir -p /home/sabnzbd/.sabnzbd

# Also create the alternative config location for flexibility
mkdir -p /var/lib/sabnzbd/.sabnzbd

# Set proper ownership NOW, before installation
# This prevents permission errors on first startup
chown -R sabnzbd:sabnzbd /home/sabnzbd
chown -R sabnzbd:sabnzbd /var/lib/sabnzbd

# Verify permissions are correct
print_info "Verifying directory permissions..."
if [ "$(stat -c '%U' /home/sabnzbd)" = "sabnzbd" ]; then
    print_info "Permissions set correctly"
else
    print_error "Failed to set proper permissions!"
    exit 1
fi

print_info "User and directory setup complete"

# ============================================================================
# STEP 5: Install SABnzbd dependencies
# ============================================================================
print_info "Installing SABnzbd dependencies..."

# par2 - Used for repairing incomplete downloads
print_info "Installing par2 (for repairing downloads)..."
apt install -y par2

# unrar - Used for extracting RAR archives
print_info "Installing unrar (for RAR extraction)..."
apt install -y unrar

# p7zip-full - Used for 7z and other archive formats
print_info "Installing p7zip-full (for 7z extraction)..."
apt install -y p7zip-full

# unzip - Additional archive support
print_info "Installing unzip (for ZIP extraction)..."
apt install -y unzip

print_info "All dependencies installed successfully"

# ============================================================================
# STEP 6: Install SABnzbd from Debian Backports
# ============================================================================
print_info "Installing SABnzbd from Debian Backports..."
print_info "This ensures you get a recent, supported version"

# Install from backports repository with -y flag to avoid prompts
# The user and directories already exist, so no permission issues should occur
apt install -t bookworm-backports sabnzbdplus -y

print_info "SABnzbd package installed successfully"

# ============================================================================
# STEP 7: Create systemd service file
# ============================================================================
print_info "Creating systemd service file..."

# Create service file that will start SABnzbd on boot
cat <<'EOF' > /etc/systemd/system/sabnzbd.service
[Unit]
Description=SABnzbd Binary Newsreader
After=network.target

[Service]
Type=simple
User=sabnzbd
Group=sabnzbd
ExecStart=/usr/bin/sabnzbdplus --browser 0 --server 0.0.0.0:8080
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

print_info "Systemd service file created"

# ============================================================================
# STEP 8: Enable and start SABnzbd service
# ============================================================================
print_info "Configuring SABnzbd to start on boot..."

# Reload systemd to recognize the new service file
systemctl daemon-reload

# Enable service to start automatically on boot
systemctl enable sabnzbd

print_info "Starting SABnzbd service..."
systemctl start sabnzbd

# Wait a moment for service to start
sleep 5

# ============================================================================
# STEP 9: Verify installation
# ============================================================================
print_info "Verifying SABnzbd service status..."

if systemctl is-active --quiet sabnzbd; then
    print_info "SABnzbd is running successfully!"
    
    # Get the container's IP address
    IP_ADDR=$(hostname -I | awk '{print $1}')
    
    echo ""
    print_info "=========================================="
    print_info "SABnzbd Installation Complete!"
    print_info "=========================================="
    echo ""
    print_info "Access SABnzbd at: http://${IP_ADDR}:8080"
    echo ""
    print_info "Useful commands:"
    echo "  - Check status:  systemctl status sabnzbd"
    echo "  - Stop service:  systemctl stop sabnzbd"
    echo "  - Start service: systemctl start sabnzbd"
    echo "  - View logs:     journalctl -u sabnzbd -f"
    echo ""
    print_info "To update SABnzbd in the future, run:"
    echo "  apt update && apt install -t bookworm-backports sabnzbdplus -y"
    echo ""
else
    print_error "SABnzbd failed to start!"
    print_error "Check logs with: journalctl -u sabnzbd -xe"
    exit 1
fi

exit 0
