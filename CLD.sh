#!/bin/bash
#
#####
# Proxmox LXC Container Creation Script with flexible configuration
# Created by mikeg91 - Enhanced version
# Updated for Proxmox 9.1.5 compatibility
#
# Notes:
# - Added nesting=1 for Debian 12/systemd compatibility on PVE 9.x
# - Implemented Start-Stop-Set logic for mount point reliability
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

MOUNT_POINTS=()
while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    read -r device mountpoint fstype rest <<< "$line"
    [[ -z "$mountpoint" ]] && continue
    [[ "$fstype" =~ ^(swap|proc|tmpfs|devpts|sysfs|devtmpfs|cgroup.*|securityfs|debugfs|configfs|fusectl|pstore|bpf|tracefs|hugetlbfs|mqueue|autofs)$ ]] && continue
    [[ "$mountpoint" =~ ^(/|/boot.*)$ ]] && continue
    MOUNT_POINTS+=("$mountpoint")
done < /etc/fstab

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
            if [[ -z "$selection" ]]; then break; fi
            if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#MOUNT_POINTS[@]} ]; then
                echo -e "${RED}Invalid selection${NC}"
                continue
            fi
            idx=$((selection-1))
            HOST_PATH="${MOUNT_POINTS[$idx]}"
            DEFAULT_CONTAINER_PATH="/mnt/$(basename "$HOST_PATH")"
            CONTAINER_PATH=$(prompt_input "Container mount path" "$DEFAULT_CONTAINER_PATH")
            if prompt_yes_no "Mount as read-only?"; then READONLY=1; else READONLY=0; fi
            SELECTED_MOUNTS+=("$HOST_PATH|$CONTAINER_PATH|$READONLY")
            echo -e "${GREEN}Added: $HOST_PATH → $CONTAINER_PATH${NC}"
        done
    else
        SELECTED_MOUNTS=()
    fi
fi

### Get latest Debian 12 template
echo ""
echo -e "${YELLOW}Resolving latest Debian 12 template...${NC}"
TEMPLATE=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | tail -n1)
if [[ ! -f "/var/lib/vz/template/cache/$TEMPLATE" ]]; then
    echo -e "${YELLOW}Downloading $TEMPLATE...${NC}"
    pveam update && pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

### Create container with Nesting enabled
echo -e "${GREEN}Creating container with nesting enabled...${NC}"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "$STORAGE:$DISK_SIZE" \
    --net0 name=eth0,bridge="$NETWORK_BRIDGE",firewall=1,ip=dhcp \
    --unprivileged 1 \
    --features "nesting=1" \
    --password "$PASSWORD" \
    --start 0

### iGPU passthrough configuration
if [ "$IS_PLEX" = true ]; then
    DETECTED_CARD=$(ls /dev/dri/card* 2>/dev/null | head -n 1)
    if [[ -n "$DETECTED_CARD" ]]; then
        cat >> "/etc/pve/lxc/${CTID}.conf" << EOF
dev0: /dev/dri/renderD128,gid=44,uid=100000,mode=0660
dev1: $DETECTED_CARD,gid=44,uid=100000,mode=0660
EOF
    fi
fi

### PHASE 1: Start container (No mounts yet, so it won't crash)
echo -e "${GREEN}Starting container for directory creation...${NC}"
pct start "$CTID"
sleep 5

### PHASE 2: Create directories inside
if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
    echo -e "${YELLOW}Creating destination directories inside container...${NC}"
    for mount_info in "${SELECTED_MOUNTS[@]}"; do
        IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY <<< "$mount_info"
        pct exec "$CTID" -- mkdir -p "$CONTAINER_PATH"
    done

    ### PHASE 3: Stop container
    echo -e "${YELLOW}Stopping container to apply mount configuration...${NC}"
    pct stop "$CTID"
    
    ### PHASE 4: Modify Config
    echo -e "${GREEN}Applying mount points to configuration...${NC}"
    for i in "${!SELECTED_MOUNTS[@]}"; do
        IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY <<< "${SELECTED_MOUNTS[$i]}"
        if [ "$READONLY" -eq 1 ]; then
            pct set "$CTID" -mp$i "$HOST_PATH,mp=$CONTAINER_PATH,ro=1"
        else
            pct set "$CTID" -mp$i "$HOST_PATH,mp=$CONTAINER_PATH"
        fi
    done

    ### PHASE 5: Final Start
    echo -e "${GREEN}Restarting container with mounts active...${NC}"
    pct start "$CTID"
    sleep 5
fi

# Configure apt sources and install updates
echo -e "${GREEN}Finalizing system configuration...${NC}"
pct exec $CTID -- bash -c "
cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF
apt update && apt upgrade -y && apt install -y curl gnupg unattended-upgrades
"

# Install Plex-specific packages
if [ "$IS_PLEX" = true ]; then
    pct exec $CTID -- apt install -y intel-media-va-driver-non-free vainfo
fi

echo -e "${GREEN}=== Configuration Complete ===${NC}"
echo "Container ID: $CTID"
echo "Nesting: Enabled"
if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
    echo "Mount Points: ${#SELECTED_MOUNTS[@]} added successfully."
fi
