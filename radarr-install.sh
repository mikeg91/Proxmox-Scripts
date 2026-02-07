#!/bin/bash
set -e

echo "== Installing Radarr =="

# Basic deps
apt update
apt install -y \
  curl \
  sqlite3 \
  ca-certificates \
  gnupg

# Create radarr user/group if missing
if ! id radarr &>/dev/null; then
  useradd -r -m -d /var/lib/radarr -s /usr/sbin/nologin radarr
fi

# Add Radarr repo + key
install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://radarr.servarr.com/v1/repo/setup.sh | bash

# Install Radarr
apt update
apt install -y radarr

# Ensure permissions
chown -R radarr:radarr \
  /var/lib/radarr \
  /etc/radarr \
  /var/log/radarr

# Enable + start
systemctl enable radarr
systemctl start radarr

echo ""
echo "Radarr installed successfully"
echo "Web UI: http://<container-ip>:7878"
