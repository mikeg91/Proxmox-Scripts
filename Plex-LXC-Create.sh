#!/bin/bash

# Proxmox LXC Container Creation Script
# Debian 12, unprivileged, Intel iGPU passthrough (VAAPI-safe)
# Users can change defaults if wished.
# Line 98 needs to be modified for your nfs share

set -e

### Default configuration values
DEFAULT_CTID=100
DEFAULT_HOSTNAME="Plex"
DEFAULT_CORES=3
DEFAULT_MEMORY=8192
DEFAULT_SWAP=2048
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

### Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

### Secure password entry
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

### Get latest Debian 12 template
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

### Add NFS mount from Proxmox host
echo -e "${GREEN}Adding NFS mount (read-only)...${NC}"
pct set "$CTID" -mp0 /mnt/pve/synology,mp=/synology,ro=1

### iGPU passthrough configuration
echo -e "${GREEN}Configuring Intel iGPU passthrough...${NC}"
CONFIG_FILE="/etc/pve/lxc/${CTID}.conf"

# Logic to find the correct card node (card0 or card1)
DETECTED_CARD=$(ls /dev/dri/card* 2>/dev/null | head -n 1)

if [[ -z "$DETECTED_CARD" ]]; then
    echo -e "${RED}Error: No GPU card node found in /dev/dri!${NC}"
    echo -e "${YELLOW}Ensure your iGPU is enabled in BIOS and drivers are loaded on the host.${NC}"
    exit 1
fi

echo -e "${YELLOW}Detected GPU node: $DETECTED_CARD${NC}"

cat >> "$CONFIG_FILE" << EOF

# Intel iGPU passthrough (Auto-detected)
dev0: /dev/dri/renderD128,gid=993,mode=0666
dev1: $DETECTED_CARD,gid=44,mode=0666
lxc.apparmor.profile: unconfined
lxc.cap.drop:
EOF

### Done
echo ""
echo -e "${GREEN}=== Configuration Complete ===${NC}"
echo "Container ID: $CTID"
echo "Hostname: $HOSTNAME"
echo "Unprivileged: Yes"
echo "iGPU Passthrough: Enabled"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Start container: pct start $CTID"
echo "2. Enter container: pct enter $CTID"
echo "3. Inside container:"
echo "   - Ensure render group exists (GID 107 typical)"
echo "   - Add plex user to render group"
echo ""
echo "Example inside container:"
echo "  groupadd -g 107 render || true"
echo "  usermod -aG render plex"
echo ""
echo -e "${GREEN}Verify GPU access with: ls -l /dev/dri${NC}"
