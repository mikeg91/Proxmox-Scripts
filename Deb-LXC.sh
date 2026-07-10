#!/bin/bash
#####
# Proxmox LXC - General Base Container (Script 1)
# Target: Proxmox VE 9.1.5, unprivileged Debian 12 (bookworm)
#
# - Creates an unprivileged Debian 12 LXC with sensible defaults
# - Installs a practical base toolset (curl, wget, gnupg, htop, etc.)
# - Enables unattended-upgrades for Debian SECURITY updates only
# - Optionally binds in host mount points
# - Optionally wires Intel iGPU passthrough at the HOST level (the only
#   step that can't be added from inside the container later). Drivers are
#   left for you to install inside the container if/when you need them.
#####

set -e

### Defaults
DEFAULT_CTID=100
DEFAULT_HOSTNAME="container"
DEFAULT_CORES=2
DEFAULT_MEMORY=2048
DEFAULT_SWAP=512
DEFAULT_DISK_SIZE=8
DEFAULT_STORAGE="local-lvm"
DEFAULT_TEMPLATE_STORAGE="local"
DEFAULT_NETWORK_BRIDGE="vmbr0"

### Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

### Helpers
prompt_input() {
    local prompt_text=$1 default_value=$2 user_input
    read -r -p "$prompt_text [$default_value]: " user_input
    echo "${user_input:-$default_value}"
}

prompt_yes_no() {
    local prompt_text=$1 response
    while true; do
        read -r -p "$prompt_text (y/n): " response
        case $response in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

wait_for_container() {
    local ctid=$1 timeout=${2:-60} i=0
    while [ "$i" -lt "$timeout" ]; do
        pct exec "$ctid" -- true 2>/dev/null && return 0
        sleep 1; i=$((i + 1))
    done
    echo -e "${RED}Timed out waiting for container $ctid${NC}"; return 1
}

# Detect an Intel GPU on the host; sets INTEL_RENDER / INTEL_CARD
detect_intel_gpu() {
    INTEL_RENDER=""; INTEL_CARD=""
    local node vendor
    for node in /dev/dri/renderD*; do
        [[ -e "$node" ]] || continue
        vendor=$(cat "/sys/class/drm/$(basename "$node")/device/vendor" 2>/dev/null || echo "")
        [[ "$vendor" == "0x8086" ]] && { INTEL_RENDER="$node"; break; }
    done
    for node in /dev/dri/card[0-9]*; do
        [[ -e "$node" ]] || continue
        vendor=$(cat "/sys/class/drm/$(basename "$node")/device/vendor" 2>/dev/null || echo "")
        [[ "$vendor" == "0x8086" ]] && { INTEL_CARD="$node"; break; }
    done
    [[ -n "$INTEL_RENDER" || -n "$INTEL_CARD" ]]
}

echo -e "${GREEN}=== Proxmox LXC Base Container ===${NC}"
echo "Press Enter to accept defaults"; echo ""

### Input
CTID=$(prompt_input "Container ID" "$DEFAULT_CTID")
CT_HOSTNAME=$(prompt_input "Hostname" "$DEFAULT_HOSTNAME")
CORES=$(prompt_input "CPU Cores" "$DEFAULT_CORES")
MEMORY=$(prompt_input "Memory (MB)" "$DEFAULT_MEMORY")
SWAP=$(prompt_input "Swap (MB)" "$DEFAULT_SWAP")
DISK_SIZE=$(prompt_input "Root Disk Size (GB)" "$DEFAULT_DISK_SIZE")
STORAGE=$(prompt_input "Storage Pool" "$DEFAULT_STORAGE")
TEMPLATE_STORAGE=$(prompt_input "Template Storage" "$DEFAULT_TEMPLATE_STORAGE")
NETWORK_BRIDGE=$(prompt_input "Network Bridge" "$DEFAULT_NETWORK_BRIDGE")

[[ "$CTID" =~ ^[0-9]+$ ]] || { echo -e "${RED}Container ID must be numeric${NC}"; exit 1; }

if pct status "$CTID" &>/dev/null; then
    echo -e "${RED}Error: Container $CTID already exists${NC}"; exit 1
fi

trap 'echo -e "${RED}Script failed. Container $CTID may be incomplete. Inspect: pct config $CTID | Remove: pct destroy $CTID${NC}"' ERR

### Optional host-level Intel iGPU passthrough (the only creation-time task)
CONFIGURE_GPU=false; INSTALL_GPU_DRIVERS=false; INTEL_RENDER=""; INTEL_CARD=""
echo ""
echo -e "${BLUE}=== GPU Passthrough (host-level) ===${NC}"
if detect_intel_gpu; then
    echo -e "${GREEN}Intel GPU detected on the host:${NC}"
    echo "  Render node: ${INTEL_RENDER:-<none>}"
    echo "  Card node:   ${INTEL_CARD:-<none>}"
    echo ""
    echo "Passthrough must be wired now - it can't be added from inside the container later."
    if prompt_yes_no "Configure host-level Intel iGPU passthrough for this container?"; then
        CONFIGURE_GPU=true
        echo ""
        if prompt_yes_no "Also install the Intel VA-API drivers now (intel-media-va-driver-non-free, vainfo)?"; then
            INSTALL_GPU_DRIVERS=true
        fi
    fi
else
    echo -e "${YELLOW}No Intel GPU detected on the host; skipping passthrough${NC}"
fi

### Password
echo ""
read -r -s -p "Root Password: " PASSWORD; echo
read -r -s -p "Confirm Root Password: " PASSWORD_CONFIRM; echo
[[ -z "$PASSWORD" ]] && { echo -e "${RED}Password cannot be empty${NC}"; exit 1; }
[[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]] && { echo -e "${RED}Passwords do not match${NC}"; exit 1; }

### Mount point discovery (from /etc/fstab)
echo ""
echo -e "${BLUE}=== Discovering Mount Points on PVE Host ===${NC}"
MOUNT_POINTS=()
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    read -r device mountpoint fstype rest <<< "$line"
    [[ -z "$mountpoint" ]] && continue
    [[ "$fstype" =~ ^(swap|proc|tmpfs|devpts|sysfs|devtmpfs|cgroup.*|securityfs|debugfs|configfs|fusectl|pstore|bpf|tracefs|hugetlbfs|mqueue|autofs)$ ]] && continue
    [[ "$mountpoint" =~ ^(/|/boot.*)$ ]] && continue
    MOUNT_POINTS+=("$mountpoint")
done < /etc/fstab

if [ ${#MOUNT_POINTS[@]} -gt 0 ]; then
    IFS=$'\n' MOUNT_POINTS=($(sort -u <<<"${MOUNT_POINTS[*]}")); unset IFS
fi

SELECTED_MOUNTS=()
if [ ${#MOUNT_POINTS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No additional mount points found on the host${NC}"
else
    echo "Available mount points on the host:"
    for i in "${!MOUNT_POINTS[@]}"; do echo "  $((i + 1)). ${MOUNT_POINTS[$i]}"; done
    echo ""
    if prompt_yes_no "Would you like to add mount points to the container?"; then
        while true; do
            echo ""
            read -r -p "Enter mount point number to add (or press Enter to finish): " selection
            [[ -z "$selection" ]] && break
            if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#MOUNT_POINTS[@]} ]; then
                echo -e "${RED}Invalid selection${NC}"; continue
            fi
            idx=$((selection - 1)); HOST_PATH="${MOUNT_POINTS[$idx]}"
            echo -e "${BLUE}Selected: $HOST_PATH${NC}"
            DEFAULT_CONTAINER_PATH="/mnt/$(basename "$HOST_PATH")"
            CONTAINER_PATH=$(prompt_input "Container mount path" "$DEFAULT_CONTAINER_PATH")
            if prompt_yes_no "Mount as read-only?"; then READONLY=1; else READONLY=0; fi
            SELECTED_MOUNTS+=("$HOST_PATH|$CONTAINER_PATH|$READONLY")
            echo -e "${GREEN}Added: $HOST_PATH -> $CONTAINER_PATH (ro=$READONLY)${NC}"
        done
    fi
fi

### Resolve latest Debian 12 template
echo ""
echo -e "${YELLOW}Resolving latest Debian 12 template...${NC}"
pveam update >/dev/null 2>&1 || true
TEMPLATE=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n1)
[[ -z "$TEMPLATE" ]] && { echo -e "${RED}Failed to locate a Debian 12 template${NC}"; exit 1; }

if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q -- "$TEMPLATE"; then
    echo -e "${GREEN}Template already present: $TEMPLATE${NC}"
else
    echo -e "${YELLOW}Downloading $TEMPLATE...${NC}"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

### Create
echo -e "${GREEN}Creating container...${NC}"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" --memory "$MEMORY" --swap "$SWAP" \
    --rootfs "$STORAGE:$DISK_SIZE" \
    --net0 name=eth0,bridge="$NETWORK_BRIDGE",firewall=1,ip=dhcp \
    --unprivileged 1 --password "$PASSWORD" --start 0

### Host-level iGPU passthrough (device wiring only - no drivers here)
if [ "$CONFIGURE_GPU" = true ]; then
    echo -e "${GREEN}Wiring Intel iGPU passthrough into container config...${NC}"
    CONFIG_FILE="/etc/pve/lxc/${CTID}.conf"
    {
        echo ""
        echo "# Intel iGPU passthrough (auto-detected). gid=44 = video group."
        [[ -n "$INTEL_RENDER" ]] && echo "dev0: $INTEL_RENDER,gid=44,mode=0660"
        [[ -n "$INTEL_CARD"   ]] && echo "dev1: $INTEL_CARD,gid=44,mode=0660"
    } >> "$CONFIG_FILE"
fi

### Start + mounts
echo -e "${GREEN}Starting container...${NC}"
pct start "$CTID"; wait_for_container "$CTID"

if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
    echo -e "${GREEN}Creating mount point directories...${NC}"
    for mount_info in "${SELECTED_MOUNTS[@]}"; do
        IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY <<< "$mount_info"
        pct exec "$CTID" -- mkdir -p "$CONTAINER_PATH"
        echo -e "${GREEN}Created: $CONTAINER_PATH${NC}"
    done
    echo -e "${YELLOW}Stopping to attach mount points...${NC}"
    pct stop "$CTID"
    for i in "${!SELECTED_MOUNTS[@]}"; do
        IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY <<< "${SELECTED_MOUNTS[$i]}"
        echo -e "${YELLOW}Configuring: $HOST_PATH -> $CONTAINER_PATH${NC}"
        if [ "$READONLY" -eq 1 ]; then
            pct set "$CTID" "-mp$i" "$HOST_PATH,mp=$CONTAINER_PATH,ro=1"
        else
            pct set "$CTID" "-mp$i" "$HOST_PATH,mp=$CONTAINER_PATH"
        fi
    done
    echo -e "${YELLOW}Restarting with mount points...${NC}"
    pct start "$CTID"; wait_for_container "$CTID"
fi

### apt sources (contrib + non-free so you can add the Intel driver later)
echo -e "${GREEN}Configuring apt sources...${NC}"
pct exec "$CTID" -- bash -c "cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
EOF
"

### Base packages (+ VA-API drivers if requested during GPU setup)
BASE_PACKAGES="curl wget gnupg ca-certificates apt-transport-https unattended-upgrades apt-listchanges htop nano sudo"
if [ "$INSTALL_GPU_DRIVERS" = true ]; then
    BASE_PACKAGES="$BASE_PACKAGES intel-media-va-driver-non-free vainfo"
    echo -e "${GREEN}Intel VA-API drivers will be installed with the base system${NC}"
fi

echo -e "${GREEN}Updating system and installing base packages...${NC}"
pct exec "$CTID" -- bash -c "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt upgrade -y
  apt install -y $BASE_PACKAGES
"

### Unattended-upgrades (Debian security only)
echo -e "${GREEN}Configuring unattended-upgrades...${NC}"
pct exec "$CTID" -- bash -c "
  cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOFUUPGRADE'
Unattended-Upgrade::Origins-Pattern {
    \"origin=Debian,codename=\${distro_codename}-security,label=Debian-Security\";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::Remove-Unused-Kernel-Packages \"true\";
Unattended-Upgrade::Remove-New-Unused-Dependencies \"true\";
Unattended-Upgrade::Remove-Unused-Dependencies \"true\";

Unattended-Upgrade::Automatic-Reboot \"true\";
Unattended-Upgrade::Automatic-Reboot-Time \"02:00\";

//Unattended-Upgrade::Mail \"root\";
Unattended-Upgrade::MailReport \"on-change\";
EOFUUPGRADE

  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOFAUTO'
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
APT::Periodic::Download-Upgradeable-Packages \"1\";
APT::Periodic::AutocleanInterval \"7\";
EOFAUTO
"
echo -e "${GREEN}Unattended-upgrades configured${NC}"

### Confirm GPU node presence (and VA-API if drivers were installed)
if [ "$CONFIGURE_GPU" = true ]; then
    echo -e "${GREEN}GPU device nodes inside the container:${NC}"
    pct exec "$CTID" -- ls -l /dev/dri || echo -e "${YELLOW}/dev/dri not visible - check host driver state${NC}"
    if [ "$INSTALL_GPU_DRIVERS" = true ]; then
        echo -e "${GREEN}Verifying VA-API inside the container...${NC}"
        if pct exec "$CTID" -- vainfo >/tmp/vainfo_${CTID}.log 2>&1; then
            echo -e "${GREEN}VA-API OK:${NC}"
            pct exec "$CTID" -- sh -c "vainfo 2>/dev/null | grep -E 'Driver version|VAProfileH264' | head -n 4" || true
        else
            echo -e "${YELLOW}vainfo did not succeed - check /dev/dri and host driver state${NC}"
        fi
    fi
fi

trap - ERR

CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "")

### Summary
echo ""
echo -e "${GREEN}=== Configuration Complete ===${NC}"
echo "Container ID:        $CTID"
echo "Hostname:            $CT_HOSTNAME"
[[ -n "$CT_IP" ]] && echo "IP Address:          $CT_IP"
echo "Unprivileged:        Yes"
echo "Unattended-Upgrades: Enabled (Debian security only)"
if [ "$CONFIGURE_GPU" = true ]; then
    echo "iGPU Passthrough:    Enabled (host-level wiring)"
    echo "  Render node: $INTEL_RENDER"
    [[ -n "$INTEL_CARD" ]] && echo "  Card node:   $INTEL_CARD"
    if [ "$INSTALL_GPU_DRIVERS" = true ]; then
        echo "  VA-API drivers: Installed"
    else
        echo "  VA-API drivers: Not installed"
    fi
fi
if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
    echo ""; echo "Mount Points:"
    for mount_info in "${SELECTED_MOUNTS[@]}"; do
        IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY <<< "$mount_info"
        RO_TEXT=""; [ "$READONLY" -eq 1 ] && RO_TEXT=" (read-only)"
        echo "  $HOST_PATH -> $CONTAINER_PATH$RO_TEXT"
    done
fi
echo ""
echo -e "${GREEN}Container is ready.${NC}"
