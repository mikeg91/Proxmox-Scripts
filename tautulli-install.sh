#!/usr/bin/env bash
set -euo pipefail

echo "==> Installing prerequisites..."
apt-get update
apt-get install -y git python3 python3-setuptools

echo "==> Preparing /opt directory..."
mkdir -p /opt
cd /opt

if [[ ! -d "/opt/Tautulli" ]]; then
  echo "==> Cloning Tautulli..."
  git clone https://github.com/Tautulli/Tautulli.git
else
  echo "==> Tautulli already exists, skipping clone."
fi

echo "==> Creating tautulli user and group..."
getent group tautulli >/dev/null || addgroup tautulli
id tautulli >/dev/null 2>&1 || adduser --system --no-create-home --ingroup tautulli tautulli

echo "==> Setting ownership..."
chown -R tautulli:tautulli /opt/Tautulli

echo "==> Installing systemd service..."
cp /opt/Tautulli/init-scripts/init.systemd /lib/systemd/system/tautulli.service

echo "==> Enabling and starting Tautulli..."
systemctl daemon-reload
systemctl enable tautulli.service
systemctl start tautulli.service

echo "==> Detecting system IP..."
IP_ADDR=$(ip -4 a | awk '/inet / && $2 !~ /^127/ { sub(/\/.*/, "", $2); print $2; exit }')

echo
echo "✅ Tautulli installation complete!"
echo "🌐 Access it at: http://${IP_ADDR}:8181"
