#!/bin/bash

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

echo "Setting up copyparty..."

# Create copyparty user
id copyparty &>/dev/null || useradd -r -s /sbin/nologin -m -d /var/lib/copyparty copyparty

# Install core app
wget -q --show-progress https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py -O /usr/local/bin/copyparty-sfx.py
chmod +x /usr/local/bin/copyparty-sfx.py

# Ask for config
read -rp "Do you want to install the default config? [Y/n] " ans
if [[ "$ans" =~ ^[Yy]$|^$ ]]; then
  wget -q --show-progress https://raw.githubusercontent.com/hirakamu/script-bank/main/files/copyparty/copyparty.conf -O /etc/copyparty.conf
  echo "Config installed at /etc/copyparty.conf"
fi
echo ''

# Ask for service
read -rp "Do you want to install the systemd service file? [Y/n] " ans
if [[ "$ans" =~ ^[Yy]$|^$ ]]; then
  wget -q --show-progress https://raw.githubusercontent.com/hirakamu/script-bank/main/files/copyparty/copyparty.service -O /etc/systemd/system/copyparty.service
  systemctl daemon-reload
  systemctl enable copyparty.service
  systemctl restart copyparty.service
  echo "Service enabled and started."
fi
echo ''

# Ask for nginx config
read -rp "Do you want to install the nginx config? [Y/n] " ans
if [[ "$ans" =~ ^[Yy]$|^$ ]]; then
  wget -q --show-progress https://raw.githubusercontent.com/hirakamu/script-bank/main/files/copyparty/copyparty.nginx -O /etc/nginx/sites-available/copyparty
  ln -sf /etc/nginx/sites-available/copyparty /etc/nginx/sites-enabled/copyparty
  nginx -t && systemctl reload nginx
echo ''
fi

echo "Copyparty setup complete."
echo "You can edit the config file at /etc/copyparty.conf"
echo "If you are using nginx, make sure to reconfigure the installed configuration at /etc/nginx/sites-available/copyparty."
echo "Access the web interface at http://<your-ip>:3923"

sleep 1
exit 0
