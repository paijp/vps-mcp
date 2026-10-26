#!/bin/bash
# https://github.com/paijp/vps-subdomain-mcp
# vps-mcp-init.sh: first-boot initialisation for a VPS seminar container.
# Run once via: podman exec <name>-web /usr/local/bin/vps-mcp-init.sh
#
# Steps:
#   1. Write /etc/vps-mcp-env  (for mcp-server.service EnvironmentFile=)
#   2. Create /etc/mcp-server (holds the issued token hash at runtime)
#   3. Configure Postfix myhostname
#   4. Substitute server_name in the nginx config; reload nginx
#   5. Run certbot certonly --webroot
#   6. Switch nginx cert paths to Let's Encrypt; reload nginx
#   7. systemctl enable --now mcp-server  (not for ROLE=staging/prod)
#   8. Prepare /srv/app (ROLE set only)
#   9. Creation notification
#
# ROLE (create3 sets only): dev | staging | prod. Empty for a standalone
# container. staging/prod run no MCP server and have an empty nginx mcp.d/.
set -euo pipefail

SUBDOMAIN="${SUBDOMAIN:-}"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
# MAIL_DOMAIN is the sender domain for all outgoing mail. In the multidomain
# edition it always equals SUBDOMAIN (the container's full hostname, passed
# from the Makefile); the host relay's own hostname is not a hosted domain.
MAIL_DOMAIN="${MAIL_DOMAIN:-$SUBDOMAIN}"
# OAUTH_BASE points every container at the GitHub-login broker (OAUTH_HOST).
# GITHUB_CLIENT_ID/SECRET are set only on the oauth container itself.
OAUTH_BASE="${OAUTH_BASE:-}"
GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:-}"
GITHUB_CLIENT_SECRET="${GITHUB_CLIENT_SECRET:-}"
ROLE="${ROLE:-}"
case "$ROLE" in
    ''|dev|staging|prod) ;;
    *) echo "vps-mcp-init: unknown ROLE=$ROLE" >&2; exit 1 ;;
esac
# MCP runs everywhere except on the staging/prod containers of a create3 set.
case "$ROLE" in staging|prod) RUN_MCP=no ;; *) RUN_MCP=yes ;; esac
start_mcp() {
    if [[ $RUN_MCP == yes ]]; then systemctl enable --now mcp-server; fi
}

if [[ -z "$SUBDOMAIN" ]]; then
    echo "vps-mcp-init: SUBDOMAIN not set" >&2; exit 1
fi

# ── 0. Wait for systemd to be ready ──────────────────────────────────────────
echo "vps-mcp-init: waiting for systemd..."
for i in $(seq 60); do
    state=$(systemctl is-system-running 2>/dev/null || true)
    if [[ "$state" == "running" || "$state" == "degraded" ]]; then break; fi
    sleep 1
done
echo "vps-mcp-init: systemd ready (state=${state:-unknown})"

# ── 1. /etc/vps-mcp-env ──────────────────────────────────────────────────────
cat > /etc/vps-mcp-env <<EOF
SUBDOMAIN=${SUBDOMAIN}
MAIL_DOMAIN=${MAIL_DOMAIN}
NOTIFY_EMAIL=${NOTIFY_EMAIL}
OAUTH_BASE=${OAUTH_BASE}
GITHUB_CLIENT_ID=${GITHUB_CLIENT_ID}
GITHUB_CLIENT_SECRET=${GITHUB_CLIENT_SECRET}
ROLE=${ROLE}
EOF
chmod 640 /etc/vps-mcp-env

# ── 2. MCP credentials directory ─────────────────────────────────────────────
# Holds /etc/mcp-server/hash, written when a Bearer token is issued at login.
mkdir -p /etc/mcp-server
chmod 700 /etc/mcp-server

# ── 3. Postfix ────────────────────────────────────────────────────────────────
# MAIL_DOMAIN is always distinct from the host relay's hostname (kimoken.jp),
# so Postfix will not mistake the relay for itself and bounce with "loops back
# to myself". For default: MAIL_DOMAIN=default.DOMAIN; others: MAIL_DOMAIN=SUBDOMAIN.
postconf -e "myhostname = ${MAIL_DOMAIN}"
postconf -e "myorigin = ${MAIL_DOMAIN}"
postconf -e "relayhost = [10.89.0.1]:25"
postconf -e "smtp_tls_security_level = none"
systemctl reload-or-restart postfix

# ── 4. nginx: replace server_name placeholder ────────────────────────────────
NGINX_CONF=/etc/nginx/conf.d/vps-mcp.conf
sed -i "s/server_name _;/server_name ${SUBDOMAIN};/g" "${NGINX_CONF}"
# No MCP server on staging/prod: drop its locations so /mcp/ does not exist.
if [[ $RUN_MCP == no ]]; then rm -f /etc/nginx/mcp.d/*.conf; fi
nginx -t && systemctl reload nginx

# ── 5. certbot ───────────────────────────────────────────────────────────────
if [[ -n "${NOTIFY_EMAIL}" ]]; then
    CERTBOT_EMAIL_FLAGS="--email ${NOTIFY_EMAIL} --no-eff-email"
else
    CERTBOT_EMAIL_FLAGS="--register-unsafely-without-email"
fi
certbot certonly \
    --webroot --webroot-path /var/www/html \
    --non-interactive --agree-tos \
    ${CERTBOT_EMAIL_FLAGS} \
    --domain "${SUBDOMAIN}" \
    || { echo "vps-mcp-init: certbot failed, keeping self-signed cert" >&2
         CERT_FAILED=yes; }

# ── 6. nginx: switch to Let's Encrypt cert ───────────────────────────────────
if [[ ${CERT_FAILED:-no} == no ]]; then
    LIVE_DIR="/etc/letsencrypt/live/${SUBDOMAIN}"
    sed -i \
        -e "s|ssl_certificate .*|ssl_certificate     ${LIVE_DIR}/fullchain.pem;|" \
        -e "s|ssl_certificate_key .*|ssl_certificate_key ${LIVE_DIR}/privkey.pem;|" \
        "${NGINX_CONF}"
    nginx -t && systemctl reload nginx
fi

# ── 7. mcp-server ────────────────────────────────────────────────────────────
start_mcp

# ── 8. /srv/app (create3 sets) ───────────────────────────────────────────────
# dev starts from the skeleton as the first commit; staging and prod start
# empty and receive that commit from the host (make <fqdn>.to-stg/.to-prod), so
# all three share one history and production can always fast-forward.
if [[ -n $ROLE && ! -d /srv/app/.git ]]; then
    mkdir -p /srv/app
    git init -q -b main /srv/app
    git -C /srv/app config user.name  "vps-mcp ${SUBDOMAIN}"
    git -C /srv/app config user.email "noreply@${MAIL_DOMAIN}"
    if [[ $ROLE == dev ]]; then
        cp -a /usr/local/share/vps-mcp/app-skeleton/. /srv/app/
        git -C /srv/app add -A
        git -C /srv/app commit -q -m "skeleton (vps-mcp create3)"
    fi
fi

# ── 9. Creation notification ─────────────────────────────────────────────────
# Sends a test email to NOTIFY_EMAIL so the operator can confirm the mail
# path (container → host relay → external) before the token-issuance mail,
# and gives the exact connector details to register in Claude.ai.
if [[ -n "${NOTIFY_EMAIL}" && $RUN_MCP == no ]]; then
    /usr/sbin/sendmail -f "noreply@${MAIL_DOMAIN}" "${NOTIFY_EMAIL}" <<EOF
From: noreply@${MAIL_DOMAIN}
To: ${NOTIFY_EMAIL}
Subject: VPS ready: ${SUBDOMAIN} (${ROLE}, no MCP)

The ${ROLE} container ${SUBDOMAIN} is ready. It has no MCP connector; it is
updated only from the host (make <production-fqdn>.to-stg / .to-prod).
EOF
elif [[ -n "${NOTIFY_EMAIL}" ]]; then
    /usr/sbin/sendmail -f "noreply@${MAIL_DOMAIN}" "${NOTIFY_EMAIL}" <<EOF
From: noreply@${MAIL_DOMAIN}
To: ${NOTIFY_EMAIL}
Subject: VPS ready: ${SUBDOMAIN}

Your VPS container is ready. Add it as a custom connector in Claude.ai:

  Name: ${SUBDOMAIN}
  URL:  https://${SUBDOMAIN}/mcp/sse

When prompted, sign in with the GitHub account whose verified email is
${NOTIFY_EMAIL}. Only that account is granted access to this container.
EOF
fi

echo "vps-mcp-init: done (${SUBDOMAIN})"
