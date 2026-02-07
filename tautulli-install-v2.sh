#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing prerequisites..."
apt-get update
apt-get install -y \
  git \
  python3 \
  python3-setuptools \
  python3-venv \
  ca-certificates \
  curl \
  tzdata

echo "==> Creating /opt directory..."
mkdir -p /opt

echo "==> Creating tautulli group..."
if ! getent group tautulli >/dev/null; then
  addgroup --system tautulli
fi

echo "==> Creating tautulli user..."
if ! id tautulli >/dev/null 2>&1; then
  adduser \
    --system \
    --disabled-login \
    --disabled-password \
    --home /opt/Tautulli \
    --ingroup tautulli \
    tautulli
fi

echo "==> Installing Tautulli..."
if [[ ! -d /opt/Tautulli/.git ]]; then
  git clone https://github.com/Tautulli/Tautulli.git /opt/Tautulli
else
  echo "==> Tautulli already present, skipping clone."
fi

echo "==> Setting ownership..."
chown -R tautulli:tautulli /opt/Tautulli

echo "==> Installing systemd service..."
cat > /etc/systemd/system/tautulli.service << 'EOF'
[Unit]
Description=Tautulli - Plex Media Server Monitoring
After=network.target

[Service]
Type=simple
User=tautulli
Group=tautulli
ExecStart=/usr/bin/python3 /opt/Tautulli/Tautulli.py
WorkingDirectory=/opt/Tautulli
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

echo "==> Enabling and starting service..."
systemctl daemon-reload
systemctl enable --now tautulli.service

echo
echo "✅ Tautulli installation complete!"
echo
echo "Access it at:"
ip -4 addr show scope global | awk '/inet/ {print "  http://" $2 ":8181"}'
