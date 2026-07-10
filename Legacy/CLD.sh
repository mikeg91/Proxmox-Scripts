#!/bin/bash
#
#####
# Proxmox LXC Container Creation Script
# Updated for PVE 9.1.5 + NFS Bind Mount Compatibility
# Includes UID/GID mapping for NFS shares
#####

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

### Prompt functions
prompt_input() {
    local prompt_text=$1
    local default_value=$2
    local user_input
    read -p "$prompt_text [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

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

CTID=$(prompt_input "Container ID" "$DEFAULT_CTID")
HOSTNAME=$(prompt_input "Hostname" "$DEFAULT_HOSTNAME")
CORES=$(prompt_input "CPU Cores" "$DEFAULT_CORES")
MEMORY=$(prompt_input "Memory (MB)" "$DEFAULT_MEMORY")
SWAP=$(prompt_input "Swap (MB)" "$DEFAULT_SWAP")
DISK_SIZE=$(prompt_input "Root Disk Size (GB)" "$DEFAULT_DISK_SIZE")
STORAGE=$(prompt_input "Storage Pool" "$DEFAULT_STORAGE")
TEMPLATE_STORAGE=$(prompt_input "Template Storage" "$DEFAULT_TEMPLATE_STORAGE")
NETWORK_BRIDGE=$(prompt_input "Network Bridge" "$DEFAULT_NETWORK_BRIDGE")

echo ""
if prompt_yes_no "Is this a Plex Media Server?"; then
    IS_PLEX=true
    echo -e "${GREEN}Plex configuration will be applied${NC}"
else
    IS_PLEX=false
fi

echo ""
read -s -p "Root Password: " PASSWORD
echo
read -s -p "Confirm Root Password: " PASSWORD_CONFIRM
echo
if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
    echo -e "${RED}Passwords do not match${NC}"; exit 1
fi

if pct status "$CTID" &>/dev/null; then
    echo -e "${RED}Error: Container $CTID already exists${NC}"; exit 1
fi

echo ""
echo -e "${BLUE}=== Discovering Host Mount Points ===${NC}"
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

SELECTED_MOUNTS=()

if [ ${#MOUNT_POINTS[@]} -gt 0 ]; then
    IFS=$'\n' MOUNT_POINTS=($(sort -u <<<"${MOUNT_POINTS[*]}")); unset IFS
    echo "Available mount points on the host:"
    for i in "${!MOUNT_POINTS[@]}"; do echo "  $((i+1)). ${MOUNT_POINTS[$i]}"; done
    
    if prompt_yes_no "Would you like to add mount points to the container?"; then
        while true; do
            echo ""
            read -p "Enter mount point number (or press Enter to finish): " selection
            if [[ -z "$selection" ]]; then break; fi
            if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#MOUNT_POINTS[@]} ]; then
                echo -e "${RED}Invalid selection${NC}"; continue
            fi
            idx=$((selection-1))
            HOST_PATH="${MOUNT_POINTS[$idx]}"
            DEFAULT_CONTAINER_PATH="/mnt/$(basename "$HOST_PATH")"
            CONTAINER_PATH=$(prompt_input "Container mount path" "$DEFAULT_CONTAINER_PATH")
            if prompt_yes_no "Mount as read-only?"; then READONLY=1; else READONLY=0; fi
            SELECTED_MOUNTS+=("$HOST_PATH|$CONTAINER_PATH|$READONLY")
        done
    fi
fi

echo ""
echo -e "${YELLOW}Resolving Debian 12 template...${NC}"
TEMPLATE=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | tail -n1)
if [[ ! -f "/var/lib/vz/template/cache/$TEMPLATE" ]]; then
    echo -e "${YELLOW}Downloading $TEMPLATE...${NC}"
    pveam update && pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

### STEP 1: Create Container (Clean)
echo -e "${GREEN}Creating container...${NC}"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "$STORAGE:$DISK_SIZE" \
    --net0 name=eth0,bridge="$NETWORK_BRIDGE",firewall=1,ip=dhcp \
    --unprivileged 1 \
    --features "nesting=1,mount=nfs;cifs" \
    --password "$PASSWORD" \
    --start 0

### GPU Passthrough
if [ "$IS_PLEX" = true ]; then
    DETECTED_CARD=$(ls /dev/dri/card* 2>/dev/null | head -n 1)
    if [[ -n "$DETECTED_CARD" ]]; then
        cat >> "/etc/pve/lxc/${CTID}.conf" << EOF
dev0: /dev/dri/renderD128,gid=44,uid=100000,mode=0660
dev1: $DETECTED_CARD,gid=44,uid=100000,mode=0660
EOF
    fi
fi

### STEP 2: Boot to create directories
echo -e "${GREEN}Starting container for initial setup...${NC}"
pct start "$CTID"
echo -e "${YELLOW}Waiting for system to initialize...${NC}"
sleep 15

if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
    for mount_info in "${SELECTED_MOUNTS[@]}"; do
        IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY <<< "$mount_info"
        pct exec "$CTID" -- mkdir -p "$CONTAINER_PATH"
    done

    ### STEP 3: Stop
    echo -e "${YELLOW}Stopping to apply mounts...${NC}"
    pct stop "$CTID"
    sleep 5

    ### STEP 4: Add mounts with shift=1 for automatic UID/GID mapping
    echo -e "${GREEN}Configuring bind mounts with automatic UID/GID shifting...${NC}"
    for i in "${!SELECTED_MOUNTS[@]}"; do
        IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY <<< "${SELECTED_MOUNTS[$i]}"
        
        # Use shift=1 to automatically remap UIDs/GIDs
        # This shifts container UIDs by +100000, making them work with NFS
        if [ "$READONLY" -eq 1 ]; then
            pct set "$CTID" -mp$i "$HOST_PATH,mp=$CONTAINER_PATH,ro=1,shift=1"
        else
            pct set "$CTID" -mp$i "$HOST_PATH,mp=$CONTAINER_PATH,shift=1"
        fi
        echo -e "${GREEN}  Mounted: $HOST_PATH -> $CONTAINER_PATH (shift=1)${NC}"
    done

    ### STEP 5: Final Start
    echo -e "${GREEN}Restarting with mounts...${NC}"
    pct start "$CTID"
    sleep 5
fi

### APT and Unattended Upgrades
pct exec $CTID -- bash -c "
cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF
apt update && apt upgrade -y && apt install -y curl gnupg unattended-upgrades apt-listchanges
"

echo -e "${GREEN}Configuring unattended-upgrades...${NC}"
pct exec $CTID -- bash -c "
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOFUU'
Unattended-Upgrade::Origins-Pattern { \"origin=Debian,codename=\${distro_codename}-security,label=Debian-Security\"; };
Unattended-Upgrade::AutoFixInterruptedDpkg \"true\";
Unattended-Upgrade::Remove-Unused-Dependencies \"true\";
Unattended-Upgrade::Automatic-Reboot \"false\";
EOFUU

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOFAU'
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
EOFAU
"

if [ "$IS_PLEX" = true ]; then
    pct exec $CTID -- apt install -y intel-media-va-driver-non-free vainfo
fi

echo -e "${GREEN}=== Complete ===${NC}"
echo ""
echo -e "${GREEN}Container $CTID ($HOSTNAME) is ready!${NC}"
if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
    echo -e "${YELLOW}Note: Bind mounts configured with shift=1 for automatic UID/GID mapping${NC}"
fi
