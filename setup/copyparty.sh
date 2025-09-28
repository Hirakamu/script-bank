!#/bin/bash


# Install core app
wget https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py -O /usr/local/bin/copyparty-sfx.py
chmod +x /usr/local/bin/copyparty-sfx.py
ln -s /usr/local/bin/copyparty-sfx.py /usr/local/bin/copyparty

useradd -r -s /sbin/nologin -m -d /var/lib/copyparty copyparty

