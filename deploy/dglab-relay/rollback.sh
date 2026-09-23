#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NGINX_CONFIG="${NGINX_CONFIG:-/opt/proxy-admin/nginx/nginx.conf}"
NGINX_CONTAINER="${NGINX_CONTAINER:-proxy-admin-nginx-1}"
BACKUP_FILE="$ROOT/.last-nginx-backup"

if [ -f "$BACKUP_FILE" ]; then
    backup="$(cat "$BACKUP_FILE")"
    if [ -f "$backup" ]; then
        cp "$backup" "$NGINX_CONFIG"
        docker exec "$NGINX_CONTAINER" nginx -t
        docker exec "$NGINX_CONTAINER" nginx -s reload
    fi
fi

cd "$ROOT"
docker compose down
echo "DG-LAB V4 Relay rolled back."
