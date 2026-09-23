#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NGINX_CONFIG="${NGINX_CONFIG:-/opt/proxy-admin/nginx/nginx.conf}"
NGINX_CONTAINER="${NGINX_CONTAINER:-proxy-admin-nginx-1}"

cd "$ROOT"
docker compose up -d --build
backup="$(python3 ./install_existing_proxy.py "$NGINX_CONFIG")"

if ! docker exec "$NGINX_CONTAINER" nginx -t; then
    if [ "$backup" != "unchanged" ] && [ -f "$backup" ]; then
        cp "$backup" "$NGINX_CONFIG"
    fi
    docker compose down
    echo "Nginx validation failed; configuration was restored." >&2
    exit 1
fi

docker exec "$NGINX_CONTAINER" nginx -s reload
docker compose ps
echo "DG-LAB V4 Relay deployed: wss://38.244.4.154.sslip.io:18444/dglab-v4"
