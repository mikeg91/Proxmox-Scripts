#!/bin/bash
#####
# Proxmox LXC - General Base Container (Script 1)
# Target: Proxmox VE 9.1.5, unprivileged Debian 12 (bookworm)
#
# - Creates an unprivileged Debian 12 LXC with sensible defaults
# - Installs a practical base toolset (curl, wget, gnupg, gnupg2, ca-certificates)
# - Prompts for timezone (defaults to America/New_York, all IANA zones available)
# - Optionally enables unattended-upgrades for Debian SECURITY updates only
# - Optionally binds in host mount points
# - Optionally wires Intel iGPU passthrough at the HOST level and installs
#   the VA-API drivers
#
# TODO: consider prompting whether to enable bookworm-backports.
#   Backports carries newer versions of things like: linux-cpupower, zfsutils,
#   restic, borgbackup, and newer firmware/hardware-support packages.
#   Nothing is ever pulled from backports automatically - it only applies when
#   explicitly requested:  apt install -t bookworm-backports <pkg>
#   Currently backports is enabled in sources.list but nothing installs from it.
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
DEFAULT_TIMEZONE="America/New_York"
DEFAULT_LOCALE="en_US.UTF-8"
DEFAULT_REBOOT_TIME="02:00"

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

# Full IANA zone list (timedatectl on PVE; zoneinfo fallback)
list_all_zones() {
    if command -v timedatectl >/dev/null 2>&1 && timedatectl list-timezones >/dev/null 2>&1; then
        timedatectl list-timezones
    else
        find /usr/share/zoneinfo -type f -printf '%P\n' 2>/dev/null \
            | grep -E '^[A-Z][A-Za-z_]+/' | sort
    fi
}

# Timezone picker: common zones + search fallback across all zones.
# NOTE: all menu output goes to stderr so the chosen zone is the only stdout.
prompt_timezone() {
    local zones=(
        America/New_York America/Chicago America/Denver America/Los_Angeles
        America/Anchorage Pacific/Honolulu America/Toronto America/Sao_Paulo
        Europe/London Europe/Berlin Europe/Paris Europe/Moscow
        Asia/Dubai Asia/Kolkata Asia/Shanghai Asia/Tokyo
        Australia/Sydney UTC
    )
    local n=${#zones[@]}
    local other=$((n + 1))
    local sel search matches i

    while true; do
        echo "" >&2
        echo "Timezone:" >&2
        for ((i = 0; i < n; i += 2)); do
            if [ $((i + 1)) -lt $n ]; then
                printf "  %2d) %-22s  %2d) %s\n" "$((i+1))" "${zones[$i]}" "$((i+2))" "${zones[$((i+1))]}" >&2
            else
                printf "  %2d) %s\n" "$((i+1))" "${zones[$i]}" >&2
            fi
        done
        printf "  %2d) Other (search all zones)\n" "$other" >&2

        read -r -p "Select [1 = $DEFAULT_TIMEZONE]: " sel
        sel="${sel:-1}"

        if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
            echo "Please enter a number." >&2; continue
        fi

        if [ "$sel" -ge 1 ] && [ "$sel" -le "$n" ]; then
            echo "${zones[$((sel - 1))]}"; return 0
        fi

        if [ "$sel" -eq "$other" ]; then
            read -r -p "Search (e.g. paris, denver, auckland): " search
            [[ -z "$search" ]] && continue
            mapfile -t matches < <(list_all_zones | grep -i -- "$search" || true)
            if [ ${#matches[@]} -eq 0 ]; then
                echo "No zones matched '$search'." >&2; continue
            fi
            echo "" >&2
            for i in "${!matches[@]}"; do
                printf "  %2d) %s\n" "$((i+1))" "${matches[$i]}" >&2
            done
            read -r -p "Select (or Enter to go back): " sel
            [[ -z "$sel" ]] && continue
            if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#matches[@]} ]; then
                echo "${matches[$((sel - 1))]}"; return 0
            fi
            echo "Invalid selection." >&2; continue
        fi

        echo "Invalid selection." >&2
    done
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

### Timezone
TIMEZONE=$(prompt_timezone)
echo -e "${GREEN}Timezone: $TIMEZONE${NC}"

### Unattended-upgrades
echo ""
echo -e "${BLUE}=== Unattended Upgrades ===${NC}"
ENABLE_UU=false; UU_REBOOT=false; UU_REBOOT_TIME="$DEFAULT_REBOOT_TIME"
UU_AUTOREMOVE=true; UU_MAIL=""

if prompt_yes_no "Enable unattended upgrades (Debian security updates only)?"; then
    ENABLE_UU=true
    echo -e "${YELLOW}Note: auto-reboot will restart THIS CONTAINER when an update requires it.${NC}"
    if prompt_yes_no "Automatically reboot the container when an update requires it?"; then
        UU_REBOOT=true
        UU_REBOOT_TIME=$(prompt_input "Reboot time (HH:MM)" "$DEFAULT_REBOOT_TIME")
    fi
    if prompt_yes_no "Automatically remove unused dependencies?"; then
        UU_AUTOREMOVE=true
    else
        UU_AUTOREMOVE=false
    fi
    UU_MAIL=$(prompt_input "Email address for reports (blank = none)" "")
else
    echo -e "${YELLOW}Unattended upgrades will not be installed${NC}"
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
    echo "Passthrough must be configured when the container is created."
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

### Host-level iGPU passthrough (device wiring only)
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

### Wait for DNS before touching apt (DHCP may not have settled yet)
echo -e "${GREEN}Waiting for network/DNS...${NC}"
for _ in $(seq 1 15); do
    pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
    sleep 2
done
if ! pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
    echo -e "${RED}Container cannot resolve DNS - aborting before package install.${NC}"
    echo -e "${YELLOW}Container /etc/resolv.conf:${NC}"
    pct exec "$CTID" -- cat /etc/resolv.conf || true
    exit 1
fi
echo -e "${GREEN}DNS OK${NC}"

### Locale FIRST - the fresh template has no locale generated, and pct exec
### inherits the host's LANG. Generating it here means every downstream step
### (timezone, apt, unattended-upgrades) runs without locale warnings.
echo -e "${GREEN}Generating locale $DEFAULT_LOCALE...${NC}"
pct exec "$CTID" -- bash -c "
  set -e
  # C.UTF-8 always exists and needs no generation - use it for this step itself
  export LANG=C.UTF-8 LC_ALL=C.UTF-8
  sed -i 's/^# *${DEFAULT_LOCALE} UTF-8/${DEFAULT_LOCALE} UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=${DEFAULT_LOCALE}
"

### Timezone
echo -e "${GREEN}Setting timezone to $TIMEZONE...${NC}"
pct exec "$CTID" -- bash -c "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime && echo '$TIMEZONE' > /etc/timezone"

### Stage config files on the host, then push them in (no escaping needed)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"; echo -e "${RED}Script failed. Container $CTID may be incomplete. Inspect: pct config $CTID | Remove: pct destroy $CTID${NC}"' ERR

cat > "$STAGE/sources.list" << 'EOF'
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
EOF

echo -e "${GREEN}Configuring apt sources...${NC}"
pct push "$CTID" "$STAGE/sources.list" /etc/apt/sources.list

### Package list
BASE_PACKAGES="curl wget gnupg gnupg2 ca-certificates"
[ "$ENABLE_UU" = true ] && BASE_PACKAGES="$BASE_PACKAGES unattended-upgrades"
if [ "$INSTALL_GPU_DRIVERS" = true ]; then
    BASE_PACKAGES="$BASE_PACKAGES intel-media-va-driver-non-free vainfo"
    echo -e "${GREEN}Intel VA-API drivers will be installed with the base system${NC}"
fi

### Single apt pass: sources are in place, so update -> upgrade -> install
echo -e "${GREEN}Updating system and installing base packages...${NC}"
pct exec "$CTID" -- bash -c "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt upgrade -y
  apt install -y $BASE_PACKAGES
"

### Unattended-upgrades config (only if enabled)
if [ "$ENABLE_UU" = true ]; then
    echo -e "${GREEN}Configuring unattended-upgrades...${NC}"

    cat > "$STAGE/50unattended-upgrades" << EOF
// Debian security updates only - third-party repos are NOT auto-updated.
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
};

Unattended-Upgrade::Package-Blacklist {
};

// Kernel packages don't exist in an LXC (the host kernel is shared),
// so this setting does nothing here. Left commented for reference.
//Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

Unattended-Upgrade::Remove-New-Unused-Dependencies "$([ "$UU_AUTOREMOVE" = true ] && echo true || echo false)";
Unattended-Upgrade::Remove-Unused-Dependencies "$([ "$UU_AUTOREMOVE" = true ] && echo true || echo false)";

Unattended-Upgrade::Automatic-Reboot "$([ "$UU_REBOOT" = true ] && echo true || echo false)";
Unattended-Upgrade::Automatic-Reboot-Time "$UU_REBOOT_TIME";
EOF

    if [ -n "$UU_MAIL" ]; then
        cat >> "$STAGE/50unattended-upgrades" << EOF

Unattended-Upgrade::Mail "$UU_MAIL";
Unattended-Upgrade::MailReport "on-change";
EOF
    fi

    cat > "$STAGE/20auto-upgrades" << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    pct push "$CTID" "$STAGE/50unattended-upgrades" /etc/apt/apt.conf.d/50unattended-upgrades
    pct push "$CTID" "$STAGE/20auto-upgrades"       /etc/apt/apt.conf.d/20auto-upgrades
    echo -e "${GREEN}Unattended-upgrades configured${NC}"
fi

rm -rf "$STAGE"

### Restart the container so upgraded services are actually RUNNING.
### dpkg cannot restart services via 'pct exec' (no usable systemd connection),
### so after the security upgrade the container is still running the OLD
### systemd/sshd/libssl binaries in memory until it is restarted.
echo ""
echo -e "${YELLOW}=====================================================${NC}"
echo -e "${YELLOW}  Restarting container $CTID to fully apply security${NC}"
echo -e "${YELLOW}  patches. Upgraded services (systemd, ssh, openssl)${NC}"
echo -e "${YELLOW}  keep running their old binaries until a restart.${NC}"
echo -e "${YELLOW}  Please wait - do not interrupt.${NC}"
echo -e "${YELLOW}=====================================================${NC}"
pct reboot "$CTID"
wait_for_container "$CTID"
echo -e "${GREEN}Container restarted - security patches are now in effect${NC}"

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
echo "Timezone:            $TIMEZONE"
echo "Unprivileged:        Yes"
if [ "$ENABLE_UU" = true ]; then
    echo "Unattended-Upgrades: Enabled (Debian security only)"
    if [ "$UU_REBOOT" = true ]; then
        echo "  Auto-reboot:      Yes (at $UU_REBOOT_TIME)"
    else
        echo "  Auto-reboot:      No"
    fi
    echo "  Auto-remove deps: $([ "$UU_AUTOREMOVE" = true ] && echo Yes || echo No)"
    [[ -n "$UU_MAIL" ]] && echo "  Mail reports to:  $UU_MAIL"
else
    echo "Unattended-Upgrades: Disabled"
fi
if [ "$CONFIGURE_GPU" = true ]; then
    echo "iGPU Passthrough:    Enabled (host-level wiring)"
    echo "  Render node: $INTEL_RENDER"
    [[ -n "$INTEL_CARD" ]] && echo "  Card node:   $INTEL_CARD"
    echo "  VA-API drivers: $([ "$INSTALL_GPU_DRIVERS" = true ] && echo Installed || echo "Not installed")"
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
