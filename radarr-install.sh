#!/bin/bash
set -e

echo "== Radarr Hands-On Install (Servarr Wiki) =="

# 1) Update + prerequisites
apt update
apt install -y curl sqlite3

# 2) Create radarr user + media group
if ! grep -q "^media:" /etc/group; then
  groupadd media
fi

if ! id radarr &>/dev/null; then
  useradd -r -m -s /usr/sbin/nologin -G media radarr
else
  # ensure radarr is in media group
  usermod -aG media radarr
fi

# 3) Prepare directories
mkdir -p /var/lib/radarr
chown radarr:media /var/lib/radarr

# 4) Determine architecture string
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  amd64) RADARCH="x64" ;;
  arm64) RADARCH="arm64" ;;
  armhf|armel) RADARCH="arm" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

# 5) Download Radarr binary release
echo "Downloading Radarr .tar.gz for arch: $RADARCH"
wget --content-disposition \
  "https://radarr.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=${RADARCH}"

# 6) Extract install
tar -xvzf Radarr*.linux*.tar.gz
mv Radarr /opt/

# 7) Ownership
chown -R radarr:media /opt/Radarr

# 8) Create systemd service
cat > /etc/systemd/system/radarr.service << 'EOF'
[Unit]
Description=Radarr Daemon
After=syslog.target network.target

[Service]
User=radarr
Group=media
Type=simple
ExecStart=/opt/Radarr/Radarr -nobrowser -data=/var/lib/radarr/
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# 9) Enable + start
systemctl daemon-reload
systemctl enable --now radarr

# 10) Cleanup tarball
rm Radarr*.linux*.tar.gz

IP=$(ip -4 addr show scope global | awk '/inet/ {print $2}' | cut -d/ -f1 | head -n1)

echo ""
echo "== Radarr Installed =="
echo "Web UI: http://${IP}:7878"
