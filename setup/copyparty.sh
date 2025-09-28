#!/bin/bash

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

echo "Setting up copyparty..."
sleep 2

# Create copyparty user
useradd -r -s /sbin/nologin -m -d /var/lib/copyparty copyparty

# Install core app
wget https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py -O /usr/local/bin/copyparty-sfx.py
chmod +x /usr/local/bin/copyparty-sfx.py

# Download default config
wget https://raw.githubusercontent.com/hirakamu/script-bank/main/files/copyparty/copyparty.conf -O /etc/copyparty.conf

# Setup systemd service
wget https://raw.githubusercontent.com/hirakamu/script-bank/main/files/copyparty/copyparty.service -O /etc/systemd/system/copyparty.service
systemctl daemon-reload
systemctl enable copyparty.service
systemctl start copyparty.service
systemctl restart copyparty.service

echo "Currently youre using the default config. Please do 'sudo nano /etc/copyparty.conf' to edit and configure."
echo "Copyparty setup complete. The service is now running."
