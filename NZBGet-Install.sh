#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF' > /etc/apt/sources.list
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
EOF

apt update

apt upgrade -y

apt install -y curl gnupg

curl -fsSL https://nzbgetcom.github.io/nzbgetcom.asc | gpg --dearmor -o /etc/apt/keyrings/nzbgetcom.gpg

echo "deb [signed-by=/etc/apt/keyrings/nzbgetcom.gpg] https://nzbgetcom.github.io/deb stable main" > /etc/apt/sources.list.d/nzbgetcom.list

apt update

apt install -y par2

apt install -y unrar-free

apt install -y nzbget

cat <<'EOF' > /etc/systemd/system/nzbget.service
[Unit]
Description=NZBGet Daemon
Documentation=http://nzbget.net/Documentation
After=network.target

[Service]
User=root
Group=root
Type=forking
ExecStart=/usr/bin/nzbget -c /etc/nzbget.conf -D
ExecStop=/usr/bin/nzbget -c /etc/nzbget.conf -Q
ExecReload=/usr/bin/nzbget -c /etc/nzbget.conf -O
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl enable nzbget

sed -i "s|UnrarCmd=unrar|UnrarCmd=unrar-free|g" /etc/nzbget.conf

sed -i "s|SevenZipCmd=7zz|SevenZipCmd=7z|g" /etc/nzbget.conf

sed -i 's/ControlIP=127.0.0.1/ControlIP=0.0.0.0/' /etc/nzbget.conf

systemctl start nzbget

systemctl is-active --quiet nzbget || { echo "NZBGet failed to start"; exit 1; }

echo "NZBGet installation completed successfully"

exit 0
