#!/usr/bin/env bash
set -e

echo "== SABnzbd simple install script =="

# ----------------------------
# Must be root
# ----------------------------
[ "$EUID" -eq 0 ] || { echo "Run as root"; exit 1; }

# ----------------------------
# Add non-free + backports
# ----------------------------
echo "Adding Debian repositories (non-free + backports)..."

cat > /etc/apt/sources.list.d/sabnzbd.list <<EOF
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
EOF

apt update

# ----------------------------
# Install prerequisites
# ----------------------------
echo "Installing prerequisites..."

apt install -y \
  curl \
  gnupg \
  par2 \
  unrar \
  p7zip-full \
  unzip

# ----------------------------
# Install SABnzbd from backports
# ----------------------------
echo "Installing SABnzbd..."

apt install -y -t bookworm-backports sabnzbdplus

# ----------------------------
# Create sabnzbd system user
# ----------------------------
echo "Creating sabnzbd user..."

id sabnzbd &>/dev/null || useradd \
  --system \
  --home /var/lib/sabnzbd \
  --shell /usr/sbin/nologin \
  sabnzbd

mkdir -p /var/lib/sabnzbd/.sabnzbd
chown -R sabnzbd:sabnzbd /var/lib/sabnzbd

# ----------------------------
# Create systemd service
# ----------------------------
echo "Creating systemd service..."

cat > /etc/systemd/system/sabnzbd.service <<EOF
[Unit]
Description=SABnzbd
After=network-online.target
Wants=network-online.target

[Service]
User=sabnzbd
Group=sabnzbd
WorkingDirectory=/var/lib/sabnzbd
ExecStart=/usr/bin/sabnzbdplus \
  --config-file /var/lib/sabnzbd/.sabnzbd \
  --server 0.0.0.0:8080 \
  --browser 0
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# ----------------------------
# Enable & start service
# ----------------------------
systemctl daemon-reload
systemctl enable sabnzbd
systemctl start sabnzbd

# ----------------------------
# Done
# ----------------------------
IP=$(hostname -I | awk '{print $1}')

echo ""
echo "SABnzbd installed and running"
echo "Access it at: http://$IP:8080"
echo ""
echo "Logs: journalctl -u sabnzbd -f"
