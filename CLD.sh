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
DEFAULT_NFS_UID=1000
DEFAULT_NFS_GID=1000

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
NEEDS_NFS_MAPPING=false

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
            
            # Check if this is an NFS mount
            if grep -q "^[^ ]* $HOST_PATH nfs" /etc/fstab 2>/dev/null; then
                NEEDS_NFS_MAPPING=true
            fi
        done
    fi
fi

# Auto-detect NFS UID/GID mapping if NFS mounts detected
NFS_UID=$DEFAULT_NFS_UID
NFS_GID=$DEFAULT_NFS_GID
if [ "$NEEDS_NFS_MAPPING" = true ]; then
    echo ""
    echo -e "${YELLOW}NFS mount detected. Detecting UID/GID from mount points...${NC}"
    
    # Try to detect UID/GID from the first NFS mount point
    DETECTED_UID=""
    DETECTED_GID=""
    DETECTED_ADDITIONAL_GIDS=()
    
    for mount_info in "${SELECTED_MOUNTS[@]}"; do
        IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY <<< "$mount_info"
        if grep -q "^[^ ]* $HOST_PATH nfs" /etc/fstab 2>/dev/null; then
            if [ -d "$HOST_PATH" ]; then
                echo -e "${BLUE}Scanning $HOST_PATH for ownership...${NC}"
                
                # Collect unique UIDs and GIDs from files in the NFS share
                FOUND_UIDS=$(find "$HOST_PATH" -maxdepth 3 2>/dev/null | head -n 20 | xargs -r stat -c '%u' 2>/dev/null | sort -u)
                FOUND_GIDS=$(find "$HOST_PATH" -maxdepth 3 2>/dev/null | head -n 20 | xargs -r stat -c '%g' 2>/dev/null | sort -u)
                
                # Use the most common non-root UID (or first found)
                for uid in $FOUND_UIDS; do
                    if [ "$uid" != "0" ] && [ -z "$DETECTED_UID" ]; then
                        DETECTED_UID=$uid
                    fi
                done
                
                # Collect all non-root GIDs
                for gid in $FOUND_GIDS; do
                    if [ "$gid" != "0" ]; then
                        if [ -z "$DETECTED_GID" ]; then
                            DETECTED_GID=$gid
                        elif [ "$gid" != "$DETECTED_GID" ]; then
                            DETECTED_ADDITIONAL_GIDS+=("$gid")
                        fi
                    fi
                done
                
                if [ -n "$DETECTED_UID" ] && [ -n "$DETECTED_GID" ]; then
                    echo -e "${GREEN}Primary UID: $DETECTED_UID${NC}"
                    echo -e "${GREEN}Primary GID: $DETECTED_GID${NC}"
                    if [ ${#DETECTED_ADDITIONAL_GIDS[@]} -gt 0 ]; then
                        echo -e "${YELLOW}Additional GIDs found: ${DETECTED_ADDITIONAL_GIDS[*]}${NC}"
                    fi
                    break
                fi
            fi
        fi
    done
    
    # Use detected values as defaults
    if [ -n "$DETECTED_UID" ]; then
        NFS_UID=$DETECTED_UID
    fi
    if [ -n "$DETECTED_GID" ]; then
        NFS_GID=$DETECTED_GID
    fi
    
    echo ""
    if prompt_yes_no "Use detected UID=$NFS_UID and GID=$NFS_GID?"; then
        echo -e "${GREEN}Using UID=$NFS_UID, GID=$NFS_GID${NC}"
        
        # Ask about additional GIDs if found
        if [ ${#DETECTED_ADDITIONAL_GIDS[@]} -gt 0 ]; then
            echo ""
            echo -e "${YELLOW}Additional GIDs detected: ${DETECTED_ADDITIONAL_GIDS[*]}${NC}"
            if prompt_yes_no "Map these additional GIDs as well?"; then
                NFS_ADDITIONAL_GIDS=("${DETECTED_ADDITIONAL_GIDS[@]}")
            else
                NFS_ADDITIONAL_GIDS=()
            fi
        else
            NFS_ADDITIONAL_GIDS=()
        fi
    else
        echo ""
        echo -e "${YELLOW}Manual override - enter custom values:${NC}"
        NFS_UID=$(prompt_input "NFS User ID (UID)" "$NFS_UID")
        NFS_GID=$(prompt_input "NFS Group ID (GID)" "$NFS_GID")
        NFS_ADDITIONAL_GIDS=()
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

### STEP 1.5: Configure UID/GID mapping for NFS compatibility
if [ "$NEEDS_NFS_MAPPING" = true ]; then
    echo -e "${GREEN}Configuring UID/GID mapping for NFS...${NC}"
    
    # Stop container if running
    pct stop "$CTID" 2>/dev/null || true
    sleep 2
    
    # Backup original config
    cp "/etc/pve/lxc/${CTID}.conf" "/etc/pve/lxc/${CTID}.conf.bak"
    
    # Collect all IDs that need direct mapping
    ALL_MAPPED_GIDS=("$NFS_GID")
    if [ ${#NFS_ADDITIONAL_GIDS[@]} -gt 0 ]; then
        ALL_MAPPED_GIDS+=("${NFS_ADDITIONAL_GIDS[@]}")
    fi
    
    # Sort and deduplicate the GID list
    IFS=$'\n' ALL_MAPPED_GIDS=($(printf '%s\n' "${ALL_MAPPED_GIDS[@]}" | sort -nu)); unset IFS
    
    echo -e "${YELLOW}Mapping UID: $NFS_UID${NC}"
    echo -e "${YELLOW}Mapping GIDs: ${ALL_MAPPED_GIDS[*]}${NC}"
    
    # Build UID mapping
    # Strategy: Create ranges between each directly-mapped ID
    declare -a UID_RANGES
    declare -a GID_RANGES
    
    # UID mapping is simpler - just map the NFS_UID
    CURRENT_CONTAINER=0
    CURRENT_HOST=100000
    
    if [ "$NFS_UID" -gt 0 ]; then
        # Range before NFS_UID
        UID_RANGES+=("u 0 100000 $NFS_UID")
        CURRENT_CONTAINER=$NFS_UID
        CURRENT_HOST=$((100000 + NFS_UID))
    fi
    
    # Direct map NFS_UID
    UID_RANGES+=("u $NFS_UID $NFS_UID 1")
    CURRENT_CONTAINER=$((NFS_UID + 1))
    
    # Range after NFS_UID to end
    REMAINING=$((65536 - CURRENT_CONTAINER))
    if [ "$REMAINING" -gt 0 ]; then
        UID_RANGES+=("u $CURRENT_CONTAINER $CURRENT_HOST $REMAINING")
    fi
    
    # GID mapping - handle multiple direct mappings
    CURRENT_CONTAINER=0
    CURRENT_HOST=100000
    
    for mapped_gid in "${ALL_MAPPED_GIDS[@]}"; do
        # Add range before this GID if needed
        if [ "$mapped_gid" -gt "$CURRENT_CONTAINER" ]; then
            RANGE_SIZE=$((mapped_gid - CURRENT_CONTAINER))
            GID_RANGES+=("g $CURRENT_CONTAINER $CURRENT_HOST $RANGE_SIZE")
            CURRENT_HOST=$((CURRENT_HOST + RANGE_SIZE))
        fi
        
        # Direct map this GID
        GID_RANGES+=("g $mapped_gid $mapped_gid 1")
        CURRENT_CONTAINER=$((mapped_gid + 1))
        # Don't increment CURRENT_HOST - we skip one ID in the unprivileged range
    done
    
    # Final range after all mapped GIDs
    REMAINING=$((65536 - CURRENT_CONTAINER))
    if [ "$REMAINING" -gt 0 ]; then
        GID_RANGES+=("g $CURRENT_CONTAINER $CURRENT_HOST $REMAINING")
    fi
    
    # Write all mappings to config
    for mapping in "${UID_RANGES[@]}"; do
        echo "lxc.idmap: $mapping" >> "/etc/pve/lxc/${CTID}.conf"
    done
    
    for mapping in "${GID_RANGES[@]}"; do
        echo "lxc.idmap: $mapping" >> "/etc/pve/lxc/${CTID}.conf"
    done
    
    # Update subuid/subgid on host to allow direct mapping
    if ! grep -q "root:$NFS_UID:1" /etc/subuid 2>/dev/null; then
        echo "root:$NFS_UID:1" >> /etc/subuid
    fi
    
    for mapped_gid in "${ALL_MAPPED_GIDS[@]}"; do
        if ! grep -q "root:$mapped_gid:1" /etc/subgid 2>/dev/null; then
            echo "root:$mapped_gid:1" >> /etc/subgid
        fi
    done
    
    echo -e "${GREEN}UID/GID mapping configured${NC}"
    echo -e "${YELLOW}Mapping details written to /etc/pve/lxc/${CTID}.conf${NC}"
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

    ### STEP 4: Modify Config with mounts
    for i in "${!SELECTED_MOUNTS[@]}"; do
        IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY <<< "${SELECTED_MOUNTS[$i]}"
        # For NFS with UID mapping, we don't need idmap=0
        if [ "$NEEDS_NFS_MAPPING" = true ]; then
            if [ "$READONLY" -eq 1 ]; then
                pct set "$CTID" -mp$i "$HOST_PATH,mp=$CONTAINER_PATH,ro=1"
            else
                pct set "$CTID" -mp$i "$HOST_PATH,mp=$CONTAINER_PATH"
            fi
        else
            # For non-NFS mounts, use idmap=0
            if [ "$READONLY" -eq 1 ]; then
                pct set "$CTID" -mp$i "$HOST_PATH,mp=$CONTAINER_PATH,ro=1,idmap=0"
            else
                pct set "$CTID" -mp$i "$HOST_PATH,mp=$CONTAINER_PATH,idmap=0"
            fi
        fi
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
if [ "$NEEDS_NFS_MAPPING" = true ]; then
    echo -e "${YELLOW}Note: UID/GID mapping applied for NFS compatibility${NC}"
    echo -e "${YELLOW}Container UID/GID $NFS_UID maps directly to host UID/GID $NFS_UID${NC}"
    echo ""
fi
echo -e "${GREEN}Container $CTID ($HOSTNAME) is ready!${NC}"
