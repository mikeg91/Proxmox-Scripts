#!/usr/bin/env bash

set -euo pipefail

GREEN='\033[0;32m'
NC='\033[0m'

# Must be run as root
[ "$EUID" -eq 0 ] || {
    echo "Run this script as root."
    exit 1
}

echo -e "${GREEN}Installing prerequisites...${NC}"
apt update
apt install -y curl gnupg2 ca-certificates

echo -e "${GREEN}Adding Plex repository...${NC}"

mkdir -p /etc/apt/keyrings

curl -L https://downloads.plex.tv/plex-keys/PlexSign.v2.key \
    | gpg --yes --dearmor -o /etc/apt/keyrings/plexmediaserver.v2.gpg

cat >/etc/apt/sources.list.d/plex.list <<EOF
deb [signed-by=/etc/apt/keyrings/plexmediaserver.v2.gpg] https://repo.plex.tv/deb/ public main
EOF

apt update

echo -e "${GREEN}Installing Plex Media Server...${NC}"
apt install -y plexmediaserver

echo -e "${GREEN}Verifying service...${NC}"
if systemctl is-active --quiet plexmediaserver; then
    echo "Plex Media Server is running."
else
    echo "Plex Media Server is installed but is not currently running."
    systemctl status plexmediaserver --no-pager || true
fi

echo
echo -e "${GREEN}Installed version:${NC}"
apt-cache policy plexmediaserver | grep Installed

echo
echo -e "${GREEN}Logs:${NC}"
echo "  /var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs/"

IP=$(ip -4 addr show scope global | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)

echo
echo -e "${GREEN}=== Installation Complete ===${NC}"
echo "• Plex repository added and trusted"
echo "• Plex Media Server installed"
echo
echo -e "${GREEN}Access Plex at:${NC}"
echo "  http://$IP:32400/web"
