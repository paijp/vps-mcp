#!/bin/bash
# https://github.com/paijp/vps-subdomain-mcp
# certbot-deploy.sh: deploy hook called by certbot after successful renewal.
# A renewal keeps the certificate's path, so nginx only needs a reload.
# Containers from before /etc/nginx/ssl-cert.conf keep the certificate lines
# in vps-mcp.conf; those are pointed at the renewed lineage as before.
set -euo pipefail

if [[ ! -f /etc/nginx/ssl-cert.conf ]]; then
    SUBDOMAIN="${RENEWED_DOMAINS%% *}"
    NGINX_CONF=/etc/nginx/conf.d/vps-mcp.conf
    LIVE_DIR="/etc/letsencrypt/live/${SUBDOMAIN}"
    sed -i \
        -e "s|ssl_certificate .*|ssl_certificate     ${LIVE_DIR}/fullchain.pem;|" \
        -e "s|ssl_certificate_key .*|ssl_certificate_key ${LIVE_DIR}/privkey.pem;|" \
        "${NGINX_CONF}"
fi

nginx -t && systemctl reload nginx
