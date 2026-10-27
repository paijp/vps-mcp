#!/bin/bash
# https://github.com/paijp/vps-subdomain-mcp
# vps-mcp-mode.sh — certificate and forward mode of this container's nginx.
# Run by vps-mcp-init.sh and by the host (make <fqdn>.getcert / .forward /
# .unforward) through `podman exec`.
#
#   getcert           obtain / update the Let's Encrypt certificate (HTTP-01)
#                     for this hostname plus, on a production or standalone
#                     container, every name in /etc/vps-mcp/cert-names, as one
#                     certificate named after this hostname; switch
#                     /etc/nginx/ssl-cert.conf to it.
#   forward [IP]      forward mode: port 443 is passed through, still
#                     encrypted, to IP:443 (the old server keeps serving with
#                     its own certificate); port 80 answers ACME challenges
#                     locally (falling back to the old server, so its own
#                     renewals keep working) and proxies everything else to
#                     IP:80. IP defaults to /etc/vps-mcp/forward-ip.
#   unforward         back to normal: this container's nginx serves 443 again.
#                     Refused until getcert has obtained a valid certificate.
#   seed IP [ROOT]    write the "everything except the MCP server goes to IP"
#                     configuration under ROOT (default /): app.d/forward.conf
#                     instead of app.d/default.conf, and an empty
#                     /etc/vps-mcp/cert-names. create3 seeds the dev repository
#                     (ROOT=/srv/app/files) so the files reach staging and
#                     production through dev2stg / stg2prod.
#   status            print mode, forward target and certificate.
set -euo pipefail

N=/etc/nginx
ENVF=/etc/vps-mcp-env
IPF=/etc/vps-mcp/forward-ip
NAMES=/etc/vps-mcp/cert-names
SHARE=/usr/local/share/vps-mcp/nginx

die() { echo "vps-mcp-mode: $*" >&2; exit 1; }
envv() { sed -n "s/^$1=//p" "$ENVF" 2>/dev/null; }
valid_ip() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

SUBDOMAIN=$(envv SUBDOMAIN)
ROLE=$(envv ROLE)
NOTIFY_EMAIL=$(envv NOTIFY_EMAIL)
[[ -n $SUBDOMAIN ]] || die "SUBDOMAIN unknown ($ENVF); run vps-mcp-init.sh first"
LIVE=/etc/letsencrypt/live/$SUBDOMAIN

# Apply a change to the nginx configuration; restore the previous files if
# nginx rejects the result. A restart (not a reload) because port 443 moves
# between the http and stream modules.
apply() {
    local bak; bak=$(mktemp -d /var/tmp/vps-mcp-mode.XXXXXX)
    cp -a $N/listen443.conf $N/listen443-local.conf $N/ssl-cert.conf "$bak/"
    cp -a $N/http80.d $N/stream.d "$bak/"
    if "$@" && nginx -t 2>&1; then
        systemctl restart nginx
        rm -rf "$bak"
    else
        cp -a "$bak"/listen443.conf "$bak"/listen443-local.conf "$bak"/ssl-cert.conf $N/
        rm -rf $N/http80.d $N/stream.d; cp -a "$bak"/http80.d "$bak"/stream.d $N/
        rm -rf "$bak"
        die "nginx rejected the new configuration; previous files restored"
    fi
}

proxy_block() {  # proxy_block SCHEME IP — proxy directives to the old server
    cat <<EOF
    proxy_pass $1://$2;
    proxy_set_header Host              \$host;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
EOF
    if [[ $1 == https ]]; then
        printf '    proxy_ssl_server_name on;\n    proxy_ssl_name        $host;\n'
    fi
}

cert_ok() {  # a Let's Encrypt certificate is configured and not expired
    grep -q "$LIVE/fullchain.pem" $N/ssl-cert.conf &&
        openssl x509 -checkend 0 -noout -in "$LIVE/fullchain.pem" >/dev/null 2>&1
}

forward_files() {
    local ip=$1
    cat > $N/stream.d/forward.conf <<EOF
# Written by vps-mcp-mode.sh forward — removed by unforward.
stream {
    server {
        listen 443 proxy_protocol;
        proxy_pass $ip:443;
    }
}
EOF
    cat > $N/listen443.conf <<'EOF'
# Forward mode (vps-mcp-mode.sh): port 443 is the stream passthrough, so the
# HTTPS server blocks wait on 127.0.0.1:8443. unforward restores the original.
listen 127.0.0.1:8443 ssl proxy_protocol;
EOF
    echo 'listen 127.0.0.1:8444 ssl;  # forward mode' > $N/listen443-local.conf
    rm -f $N/http80.d/*.conf
    {
        echo "# Forward mode (vps-mcp-mode.sh): ACME challenges here first, then $ip."
        echo 'location /.well-known/acme-challenge/ {'
        echo '    root /var/www/html;'
        echo '    try_files $uri @old;'
        echo '}'
        echo 'location @old {'
        proxy_block http "$ip"
        echo '}'
        echo 'location / {'
        proxy_block http "$ip"
        echo '}'
    } > $N/http80.d/forward.conf
}

# The image keeps pristine copies of the switched files, so normal mode is
# exactly what the image ships (no second copy of their content here).
normal_files() {
    rm -f $N/stream.d/forward.conf
    cp $SHARE/listen443.conf $SHARE/listen443-local.conf $N/
    rm -f $N/http80.d/*.conf
    cp $SHARE/http80-default.conf $N/http80.d/default.conf
}

cmd=${1:-status}
case $cmd in
getcert)
    names=("$SUBDOMAIN")
    if [[ $ROLE == "" || $ROLE == prod ]] && [[ -f $NAMES ]]; then
        while read -r n _; do
            n=${n%%#*}
            [[ -n $n && $n != "$SUBDOMAIN" ]] && names+=("$n")
        done < "$NAMES"
    fi
    if [[ -n $NOTIFY_EMAIL ]]; then email=(--email "$NOTIFY_EMAIL" --no-eff-email)
    else email=(--register-unsafely-without-email); fi
    args=()
    for n in "${names[@]}"; do args+=(-d "$n"); done
    echo "vps-mcp-mode: requesting a certificate for: ${names[*]}"
    certbot certonly --webroot --webroot-path /var/www/html \
        --non-interactive --agree-tos "${email[@]}" \
        --cert-name "$SUBDOMAIN" "${args[@]}" ||
        die "certbot failed (are these names already pointing at this host?)"
    cat > $N/ssl-cert.conf.new <<EOF
# Let's Encrypt certificate (vps-mcp-mode.sh getcert); renewed by certbot.timer.
ssl_certificate     $LIVE/fullchain.pem;
ssl_certificate_key $LIVE/privkey.pem;
EOF
    mv $N/ssl-cert.conf.new $N/ssl-cert.conf
    if nginx -t 2>&1; then systemctl reload nginx; else die "nginx -t failed after switching the certificate"; fi
    echo "vps-mcp-mode: certificate installed"
    ;;
forward)
    ip=${2:-$(cat "$IPF" 2>/dev/null || true)}
    valid_ip "$ip" || die "usage: vps-mcp-mode.sh forward IP (no saved forward IP)"
    mkdir -p "$(dirname "$IPF")"; echo "$ip" > "$IPF"
    apply forward_files "$ip"
    echo "vps-mcp-mode: forward mode — 443 passes through to $ip, 80 proxies to $ip"
    ;;
unforward)
    [[ -f $N/stream.d/forward.conf ]] || { echo "vps-mcp-mode: not in forward mode"; exit 0; }
    cert_ok || die "no valid Let's Encrypt certificate yet; run getcert first (make $SUBDOMAIN.getcert)"
    apply normal_files
    echo "vps-mcp-mode: forward mode off — this container serves 443"
    ;;
seed)
    ip=${2:-}; root=${3:-/}
    valid_ip "$ip" || die "usage: vps-mcp-mode.sh seed IP [ROOT]"
    mkdir -p "$root/etc/nginx/app.d" "$root/etc/vps-mcp"
    rm -f "$root/etc/nginx/app.d/default.conf"
    {
        echo "# Everything that no other file in app.d/ handles goes to the old server"
        echo "# $ip (written by vps-mcp-mode.sh seed). Narrow or delete this file as"
        echo "# parts move to this server."
        echo 'location / {'
        proxy_block https "$ip"
        echo '}'
    } > "$root/etc/nginx/app.d/forward.conf"
    [[ -f $root$NAMES ]] || cat > "$root$NAMES" <<'EOF'
# Extra hostnames for this site's certificate, one per line (make <fqdn>.getcert).
# List every name under the domain that reaches this container without a
# container of its own (e.g. www, or redirect-only names). Each also needs an
# HTTPS server block in /etc/nginx/conf.d/ that includes
# /etc/nginx/listen443.conf and /etc/nginx/ssl-cert.conf.
EOF
    echo "vps-mcp-mode: seeded forward configuration for $ip under $root"
    ;;
status)
    if [[ -f $N/stream.d/forward.conf ]]; then
        echo "mode:    forward -> $(cat "$IPF" 2>/dev/null || echo '?')"
    else
        echo "mode:    normal"
    fi
    if cert_ok; then
        echo "cert:    Let's Encrypt, $(openssl x509 -noout -enddate -in "$LIVE/fullchain.pem" | sed 's/notAfter=/expires /')"
        echo "names:   $(openssl x509 -noout -ext subjectAltName -in "$LIVE/fullchain.pem" | sed -n 's/ *DNS://gp' | tr -d '\n')"
    else
        echo "cert:    none (self-signed); make $SUBDOMAIN.getcert"
    fi
    ;;
*)
    die "usage: vps-mcp-mode.sh getcert | forward [IP] | unforward | seed IP [ROOT] | status"
    ;;
esac
