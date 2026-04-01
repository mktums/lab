#!/bin/sh
set -e

mkdir -p /data/inpx-web /data/liberama

# Write inpx-web config if not present
if [ ! -f /data/inpx-web/config.json ]; then
  cat > /data/inpx-web/config.json <<'EOF'
{
  "bookReadLink": "https://LIB_DOMAIN/read/#/reader?url=${DOWNLOAD_LINK}"
}
EOF
  sed -i "s|LIB_DOMAIN|${LIB_DOMAIN}|g" /data/inpx-web/config.json
fi

# Link system Calibre into liberama's expected location
mkdir -p /data/liberama/calibre
if [ ! -L /data/liberama/calibre/ebook-convert ]; then
  ln -sf /usr/bin/ebook-convert /data/liberama/calibre/ebook-convert
fi


if [ ! -f /data/liberama/config.json ]; then
  cat > /data/liberama/config.json <<'EOF'
{
  "useExternalBookConverter": true,
  "networkLibraryLink": "https://LIB_DOMAIN",
  "servers": [
    {
      "serverName": "1",
      "mode": "reader",
      "ip": "0.0.0.0",
      "port": "44080"
    }
  ],
  "root": "/read"
}
EOF
  sed -i "s|LIB_DOMAIN|${LIB_DOMAIN}|g" /data/liberama/config.json
fi

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/apps.conf
