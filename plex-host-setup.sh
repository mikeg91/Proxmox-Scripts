#!/bin/bash

# Proxmox LXC Container Creation Script
# Creates Debian 12 container with iGPU passthrough and mount point

set -e

# Default configuration values
DEFAULT_CTID=100
DEFAULT_HOSTNAME="Plex"
DEFAULT_PASSWORD="changeme"
DEFAULT_CORES=3
DEFAULT_MEMORY=8192
DEFAULT_SWAP=2048
DEFAULT_DISK_SIZE=8
DEFAULT_STORAGE="local-lvm"
DEFAULT_TEMPLATE_STORAGE="local"
DEFAULT_NETWORK_BRIDGE="vmbr0"
# DEFAULT_HOST_MOUNT_POINT="/mnt/pve/mount-point-0"
# DEFAULT_CONTAINER_MOUNT_POINT="/mnt/media"

# Function to prompt for input with default value
prompt_input() {
    local prompt_text=$1
    local default_value=$2
    local user_input
    
    read -p "$prompt_text [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Proxmox LXC Container Creation ===${NC}"
echo "Please enter configuration values (press Enter to use default):"
echo ""

# Prompt for all configuration variables
CTID=$(prompt_input "Container ID" "$DEFAULT_CTID")
HOSTNAME=$(prompt_input "Hostname" "$DEFAULT_HOSTNAME")
PASSWORD=$(prompt_input "Root Password" "$DEFAULT_PASSWORD")
CORES=$(prompt_input "CPU Cores" "$DEFAULT_CORES")
MEMORY=$(prompt_input "Memory (MB)" "$DEFAULT_MEMORY")
SWAP=$(prompt_input "Swap (MB)" "$DEFAULT_SWAP")
DISK_SIZE=$(prompt_input "Root Disk Size (GB)" "$DEFAULT_DISK_SIZE")
STORAGE=$(prompt_input "Storage Pool" "$DEFAULT_STORAGE")
TEMPLATE_STORAGE=$(prompt_input "Template Storage" "$DEFAULT_TEMPLATE_STORAGE")
NETWORK_BRIDGE=$(prompt_input "Network Bridge" "$DEFAULT_NETWORK_BRIDGE")
# HOST_MOUNT_POINT=$(prompt_input "Host Mount Point Path" "$DEFAULT_HOST_MOUNT_POINT")
# CONTAINER_MOUNT_POINT=$(prompt_input "Container Mount Point" "$DEFAULT_CONTAINER_MOUNT_POINT")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Proxmox LXC Container Creation ===${NC}"
echo "Container ID: $CTID"
echo "Hostname: $HOSTNAME"
echo "Cores: $CORES"
echo "Memory: ${MEMORY}MB"
echo "Swap: ${SWAP}MB"
echo ""

# Check if container ID already exists
if pct status $CTID &>/dev/null; then
    echo -e "${RED}Error: Container $CTID already exists!${NC}"
    exit 1
fi

# Download Debian 12 template if not present
TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"
if [ ! -f "/var/lib/vz/template/cache/$TEMPLATE" ]; then
    echo -e "${YELLOW}Downloading Debian 12 template...${NC}"
    pveam update
    pveam download $TEMPLATE_STORAGE $TEMPLATE
fi

# Create the container
echo -e "${GREEN}Creating container...${NC}"
pct create $CTID $TEMPLATE_STORAGE:vztmpl/$TEMPLATE \
    --hostname $HOSTNAME \
    --cores $CORES \
    --memory $MEMORY \
    --swap $SWAP \
    --rootfs $STORAGE:$DISK_SIZE \
    --net0 name=eth0,bridge=$NETWORK_BRIDGE,firewall=1,ip=dhcp \
    --features nesting=1 \
    --unprivileged 0 \
    --password $PASSWORD \
    --start 0

echo -e "${GREEN}Container created successfully!${NC}"

# Configure iGPU passthrough
echo -e "${GREEN}Configuring iGPU passthrough...${NC}"
CONFIG_FILE="/etc/pve/lxc/${CTID}.conf"

# Add device passthrough for Intel iGPU
cat >> $CONFIG_FILE << EOF

# iGPU Passthrough
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.idmap: u 0 100000 1000
lxc.idmap: g 0 100000 1000
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir,uid=0,gid=44
EOF

# Add mount point (commented out - uncomment to enable)
# echo -e "${GREEN}Adding mount point...${NC}"
# cat >> $CONFIG_FILE << EOF
#
# # Host mount point
# mp0: $HOST_MOUNT_POINT,mp=$CONTAINER_MOUNT_POINT
# EOF

echo -e "${GREEN}Configuration complete!${NC}"
echo ""
echo -e "${YELLOW}Important notes:${NC}"
echo "1. Container ID: $CTID"
echo "2. Root password: $PASSWORD (change this after first login)"
echo "3. iGPU devices (/dev/dri) are passed through"
# echo "4. Host path '$HOST_MOUNT_POINT' mounted to '$CONTAINER_MOUNT_POINT'"
echo "4. Container is configured but NOT started"
echo ""
# echo -e "${YELLOW}Verify your host mount point path is correct!${NC}"
# echo "Current configuration: $HOST_MOUNT_POINT -> $CONTAINER_MOUNT_POINT"
# echo ""
echo "To start the container, run: pct start $CTID"
echo "To enter the container, run: pct enter $CTID"
echo ""
echo -e "${GREEN}After starting, verify iGPU access with: ls -la /dev/dri${NC}"
