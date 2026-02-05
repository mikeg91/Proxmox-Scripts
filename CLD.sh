#!/bin/bash
#
#####
# Proxmox LXC Container Creation Script with flexible configuration
# Created by mikeg91 - Enhanced version
# Updated for Proxmox 9.1.5 compatibility
#
# Notes to consider when using this script:
# - This script will check if you have a deb 12 release template if not it will download the newest one for you
# - This will make an unprivileged container
# - Users can configure GPU passthrough if this is a Plex server
# - Users can select mount points from the Proxmox host to add to the container
# - The script will create mount point directories before adding mounts (required for Proxmox 9.1.5+)
# - Configures unattended-upgrades for Debian security updates only (does not auto-update third-party packages)
# If you wanted to host this yourself to make recovery easy, run the following command in your pve host if it's posted in a public repo of yours in github.
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPONAME/refs/heads/main/SCRIPTNAME.sh)"
#
####

set -e

### Default configuration values
DEFAULT_CTID=100
DEFAULT_HOSTNAME="container"
DEFAULT_CORES=2
DEFAULT_MEMORY=2048
DEFAULT_SWAP=512
DEFAULT_DISK_SIZE=8
DEFAULT_STORAGE="local-lvm"
DEFAULT_TEMPLATE_STORAGE="local"
DEFAULT_NETWORK_BRIDGE="vmbr0"

### Prompt function
prompt_input() {
    local prompt_text=$1
    local default_value=$2
    local user_input
    read -p "$prompt_text [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

### Yes/No prompt function
prompt_yes_no() {
    local prompt_text=$1
    local response
    while true; do
        read -p "$prompt_text (y/n): " response
        case $response in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

### Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Proxmox LXC Container Creation ===${NC}"
echo "Press Enter to accept defaults"
echo ""

### User input
CTID=$(prompt_input "Container ID" "$DEFAULT_CTID")
HOSTNAME=$(prompt_input "Hostname" "$DEFAULT_HOSTNAME")
CORES=$(prompt_input "CPU Cores" "$DEFAULT_CORES")
MEMORY=$(prompt_input "Memory (MB)" "$DEFAULT_MEMORY")
SWAP=$(prompt_input "Swap (MB)" "$DEFAULT_SWAP")
DISK_SIZE=$(prompt_input "Root Disk Size (GB)" "$DEFAULT_DISK_SIZE")
STORAGE=$(prompt_input "Storage Pool" "$DEFAULT_STORAGE")
TEMPLATE_STORAGE=$(prompt_input "Template Storage" "$DEFAULT_TEMPLATE_STORAGE")
NETWORK_BRIDGE=$(prompt_input "Network Bridge" "$DEFAULT_NETWORK_BRIDGE")

### Ask if this is a Plex server
echo ""
if prompt_yes_no "Is this a Plex Media Server?"; then
    IS_PLEX=true
    echo -e "${GREEN}Plex configuration will be applied${NC}"
else
    IS_PLEX=false
    echo -e "${YELLOW}Skipping Plex-specific configuration${NC}"
fi

### Secure password entry
echo ""
read -s -p "Root Password: " PASSWORD
echo
read -s -p "Confirm Root Password: " PASSWORD_CONFIRM
echo

if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
    echo -e "${RED}Passwords do not match${NC}"
    exit 1
fi

### Check for existing CT
if pct status "$CTID" &>/dev/null; then
    echo -e "${RED}Error: Container $CTID already exists${NC}"
    exit 1
fi

### Discover available mount points on PVE host
echo ""
echo -e "${BLUE}=== Discovering Mount Points on PVE Host ===${NC}"

# Read mount points from /etc/fstab (NFS, CIFS, and other network mounts)
MOUNT_POINTS=()
while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    
    # Parse fstab line: device mountpoint fstype options dump pass
    read -r device mountpoint fstype rest <<< "$line"
    
    # Skip if no mountpoint
    [[ -z "$mountpoint" ]] && continue
    
    # Skip system mounts (swap, proc, tmpfs, devpts, sysfs, etc.)
    [[ "$fstype" =~ ^(swap|proc|tmpfs|devpts|sysfs|devtmpfs|cgroup.*|securityfs|debugfs|configfs|fusectl|pstore|bpf|tracefs|hugetlbfs|mqueue|autofs)$ ]] && continue
    
    # Skip root and boot partitions
    [[ "$mountpoint" =~ ^(/|/boot.*)$ ]] && continue
    
    # Add the mount point
    MOUNT_POINTS+=("$mountpoint")
done < /etc/fstab

# Sort and remove duplicates
if [ ${#MOUNT_POINTS[@]} -gt 0 ]; then
    IFS=$'\n' MOUNT_POINTS=($(sort -u <<<"${MOUNT_POINTS[*]}"))
    unset IFS
fi

if [ ${#MOUNT_POINTS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No additional mount points found on the host${NC}"
    SELECTED_MOUNTS=()
else
    echo "Available mount points on the host:"
    for i in "${!MOUNT_POINTS[@]}"; do
        echo "  $((i+1)). ${MOUNT_POINTS[$i]}"
    done
    
    echo ""
    if prompt_yes_no "Would you like to add mount points to the container?"; then
        SELECTED_MOUNTS=()
        
        while true; do
            echo ""
            read -p "Enter mount point number to add (or press Enter to finish): " selection
            
            if [[ -z "$selection" ]]; then
                break
            fi
            
            if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#MOUNT_POINTS[@]} ]; then
                echo -e "${RED}Invalid selection${NC}"
                continue
            fi
            
            idx=$((selection-1))
            HOST_PATH="${MOUNT_POINTS[$idx]}"
            
            echo -e "${BLUE}Selected: $HOST_PATH${NC}"
            
            # Ask for container mount path
            DEFAULT_CONTAINER_PATH="/mnt/$(basename "$HOST_PATH")"
            CONTAINER_PATH=$(prompt_input "Container mount path" "$DEFAULT_CONTAINER_PATH")
            
            # Ask if read-only
            if prompt_yes_no "Mount as read-only?"; then
                READONLY=1
            else
                READONLY=0
            fi
            
            SELECTED_MOUNTS+=("$HOST_PATH|$CONTAINER_PATH|$READONLY")
            echo -e "${GREEN}Added: $HOST_PATH → $CONTAINER_PATH (ro=$READONLY)${NC}"
        done
    else
        SELECTED_MOUNTS=()
    fi
fi

### Get latest Debian 12 template
echo ""
echo -e "${YELLOW}Resolving latest Debian 12 template...${NC}"
TEMPLATE=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | tail -n1)

if [[ -z "$TEMPLATE" ]]; then
    echo -e "${RED}Failed to locate Debian 12 template${NC}"
    exit 1
fi

if [[ ! -f "/var/lib/vz/template/cache/$TEMPLATE" ]]; then
    echo -e "${YELLOW}Downloading $TEMPLATE...${NC}"
    pveam update
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

### Create container
echo -e "${GREEN}Creating container...${NC}"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "$STORAGE:$DISK_SIZE" \
    --net0 name=eth0,bridge="$NETWORK_BRIDGE",firewall=1,ip=dhcp \
    --unprivileged 1 \
    --password "$PASSWORD" \
    --start 0

### iGPU passthrough configuration (only if Plex)
if [ "$IS_PLEX" = true ]; then
    echo -e "${GREEN}Configuring Intel iGPU passthrough for Plex...${NC}"
    CONFIG_FILE="/etc/pve/lxc/${CTID}.conf"

    # Logic to find the correct card node (card0 or card1)
    DETECTED_CARD=$(ls /dev/dri/card* 2>/dev/null | head -n 1)

    if [[ -z "$DETECTED_CARD" ]]; then
        echo -e "${RED}Warning: No GPU card node found in /dev/dri!${NC}"
        echo -e "${YELLOW}Ensure your iGPU is enabled in BIOS and drivers are loaded on the host.${NC}"
        echo -e "${YELLOW}Skipping GPU passthrough configuration.${NC}"
    else
        echo -e "${YELLOW}Detected GPU node: $DETECTED_CARD${NC}"

        cat >> "$CONFIG_FILE" << EOF

# Intel iGPU passthrough (Auto-detected)
dev0: /dev/dri/renderD128,gid=44,uid=100000,mode=0660
dev1: $DETECTED_CARD,gid=44,uid=100000,mode=0660
EOF
        echo -e "${GREEN}GPU passthrough configured${NC}"
    fi
fi

### Start container WITHOUT mount points first
echo -e "${GREEN}Starting container for initial configuration...${NC}"
pct start "$CTID"

echo -e "${YELLOW}Waiting for container to initialize...${NC}"
sleep 10

### Create mount point directories inside running container
if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
    echo -e "${GREEN}Creating mount point directories...${NC}"
    
    for mount_info in "${SELECTED_MOUNTS[@]}"; do
        IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY <<< "$mount_info"
        pct exec "$CTID" -- mkdir -p "$CONTAINER_PATH"
        echo -e "${GREEN}Created directory: $CONTAINER_PATH${NC}"
    done
    
    ### NOW stop and add mount points
    echo -e "${YELLOW}Stopping container to add mount points...${NC}"
    pct stop "$CTID"
    sleep 5
    
    echo -e "${GREEN}Adding mount points to container config...${NC}"
    for i in "${!SELECTED_MOUNTS[@]}"; do
        IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY <<< "${SELECTED_MOUNTS[$i]}"
        
        echo -e "${YELLOW}Configuring: $HOST_PATH → $CONTAINER_PATH${NC}"
        
        if [ "$READONLY" -eq 1 ]; then
            pct set "$CTID" -mp$i "$HOST_PATH,mp=$CONTAINER_PATH,ro=1"
        else
            pct set "$CTID" -mp$i "$HOST_PATH,mp=$CONTAINER_PATH"
        fi
        
        echo -e "${GREEN}Added mount point $i${NC}"
    done
    
    echo -e "${YELLOW}Starting container with mount points...${NC}"
    pct start "$CTID"
    sleep 10
fi

# Configure sources.list
echo -e "${GREEN}Configuring apt sources...${NC}"
pct exec $CTID -- bash -c "cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
EOF
"

# Update and install packages
echo -e "${GREEN}Updating system and installing packages...${NC}"
pct exec $CTID -- bash -c "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt upgrade -y
  apt install -y curl gnupg unattended-upgrades apt-listchanges
"

# Configure unattended-upgrades (Debian security updates only)
echo -e "${GREEN}Configuring unattended-upgrades...${NC}"
pct exec $CTID -- bash -c "
  # Configure to only update Debian security packages
  cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOFUUPGRADE'
Unattended-Upgrade::Origins-Pattern {
    \"origin=Debian,codename=\${distro_codename}-security,label=Debian-Security\";
};

// Do not upgrade any other packages
Unattended-Upgrade::Package-Blacklist {
};

// Automatically remove unused dependencies
Unattended-Upgrade::Remove-Unused-Kernel-Packages \"true\";
Unattended-Upgrade::Remove-New-Unused-Dependencies \"true\";
Unattended-Upgrade::Remove-Unused-Dependencies \"true\";

// Enable automatic reboots if required (at 2 AM)
Unattended-Upgrade::Automatic-Reboot \"true\";
Unattended-Upgrade::Automatic-Reboot-Time \"02:00\";

// Send email notifications (configure email if needed)
//Unattended-Upgrade::Mail \"root\";
Unattended-Upgrade::MailReport \"on-change\";
EOFUUPGRADE

  # Enable automatic updates
  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOFAUTO'
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
APT::Periodic::Download-Upgradeable-Packages \"1\";
APT::Periodic::AutocleanInterval \"7\";
EOFAUTO

  echo 'Unattended-upgrades configured for Debian security updates only'
"
echo -e "${GREEN}Unattended-upgrades configured${NC}"

# Install Plex-specific packages if this is a Plex server
if [ "$IS_PLEX" = true ]; then
    echo -e "${GREEN}Installing Plex hardware transcoding packages...${NC}"
    pct exec $CTID -- bash -c "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt install -y intel-media-va-driver-non-free vainfo
    "
    echo -e "${GREEN}Intel VA-API drivers installed${NC}"
fi

echo -e "${GREEN}Successfully configured container $CTID${NC}"

### Done
echo ""
echo -e "${GREEN}=== Configuration Complete ===${NC}"
echo "Container ID: $CTID"
echo "Hostname: $HOSTNAME"
echo "Unprivileged: Yes"
echo "Unattended-Upgrades: Enabled (Debian security only)"

if [ "$IS_PLEX" = true ]; then
    echo "Plex Server: Yes"
    echo "iGPU Passthrough: Enabled"
    echo ""
    echo "GPU devices are available inside the container at:"
    echo "  /dev/dri"
    echo -e "${GREEN}Verify GPU access with: pct exec $CTID -- ls -l /dev/dri${NC}"
fi

if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
    echo ""
    echo "Mount Points:"
    for mount_info in "${SELECTED_MOUNTS[@]}"; do
        IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY <<< "$mount_info"
        RO_TEXT=""
        if [ "$READONLY" -eq 1 ]; then
            RO_TEXT=" (read-only)"
        fi
        echo "  $HOST_PATH → $CONTAINER_PATH$RO_TEXT"
    done
fi

echo ""
echo "Status: Running"
echo ""
echo -e "${GREEN}Container is ready for use!${NC}"
echo ""
echo -e "${YELLOW}Note: Unattended-upgrades will only update Debian security packages.${NC}"
echo -e "${YELLOW}Third-party software (like Plex) will NOT be automatically updated.${NC}"
