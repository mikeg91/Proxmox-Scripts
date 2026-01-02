#!/usr/bin/env bash

# Test script for plex install

set -euo pipefail

GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}Configuring Debian Bookworm sources...${NC}"

cat <<'EOF' > /etc/apt/sources.list
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org bookworm-security main contrib non-free non-free-firmware
EOF

echo -e "${GREEN}Updating system...${NC}"
apt update
apt upgrade -y

echo -e "${GREEN}Installing prerequisites...${NC}"
apt install -y curl gnupg

echo -e "${GREEN}Adding Plex repository...${NC}"
curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key \
  | gpg --dearmor \
  | tee /usr/share/keyrings/plex.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/plex.gpg] https://downloads.plex.tv/repo/deb public main" \
  > /etc/apt/sources.list.d/plexmediaserver.list

apt update

echo -e "${GREEN}Installing Intel VA-API drivers...${NC}"
apt install -y intel-media-va-driver-non-free vainfo

echo -e "${GREEN}Installing Plex Media Server...${NC}"
apt install -y plexmediaserver

echo ""
echo -e "${GREEN}=== Installation Complete ===${NC}"
echo "• Debian Bookworm sources configured"
echo "• System fully updated"
echo "• Plex repository added and trusted"
echo "• Intel VA-API drivers installed"
echo "• Plex Media Server installed"
echo ""
echo -e "${GREEN}Access Plex at:${NC}"
echo "  http://<container-ip>:32400/web"
