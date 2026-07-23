#!/bin/sh
# check-installed.sh — compare files installed by `make ...setupdone` / `make
# mcpupdate` against the current checkout, so drift (especially in configs that
# aren't refreshed by mcpupdate, like nginx/vps-mcp.conf) becomes visible.
#
# Reports one line per file:
#   OK       <path>                   installed matches repo
#   DIFFER   <path>  (source: <src>)  installed differs from repo
#   MISSING  <path>  (source: <src>)  installed file not present
#   SKIP     <path>  <reason>
#
# Exit 0 if everything is OK/SKIP, 1 if any file is DIFFER or MISSING.
#
# Run from the `full/` directory (the Makefile's `check` target does this).

set -u

if [ ! -f /etc/vps-mcp/host.env ]; then
    echo "Error: /etc/vps-mcp/host.env not found — run setupdone first." >&2
    exit 2
fi
# shellcheck disable=SC1091
. /etc/vps-mcp/host.env

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
status=0

# subst_domain FILE — expand __DOMAIN__ in FILE and print to stdout.
subst_domain() { sed "s|__DOMAIN__|$DOMAIN|g" "$1"; }

# check_pair SRC DST [render]
#   SRC     path in the repo checkout
#   DST     installed path on the live host
#   render  optional shell command that reads SRC and prints the expected
#           installed content to stdout (defaults to plain `cat`); used to
#           replay template substitutions the Makefile performed at install
#           time.
check_pair() {
    src=$1; dst=$2; render=${3:-cat}
    if [ ! -e "$src" ]; then
        echo "SKIP     $dst  (repo source $src missing)"
        return
    fi
    if [ ! -e "$dst" ]; then
        echo "MISSING  $dst  (source: $src)"
        status=1
        return
    fi
    exp="$tmp/exp.$$"
    # shellcheck disable=SC2086
    eval "$render \"\$src\"" > "$exp"
    if cmp -s "$exp" "$dst"; then
        echo "OK       $dst"
    else
        echo "DIFFER   $dst  (source: $src)"
        diff -u "$exp" "$dst" | sed 's/^/    /' | head -n 40
        status=1
    fi
    rm -f "$exp"
}

# ── MCP app (refreshed by `make mcpupdate`) ──────────────────────────────────
check_pair mcp/index.mjs                  /opt/mcp/index.mjs
check_pair mcp/package.json               /opt/mcp/package.json
check_pair systemd/mcp-server.service     /etc/systemd/system/mcp-server.service
check_pair systemd/certbot-deploy.sh      /etc/letsencrypt/renewal-hooks/deploy/vps-mcp.sh

# ── host units (only refreshed by re-running setupdone) ─────────────────────
check_pair host/systemd/vps-mcp-reboot.service  /etc/systemd/system/vps-mcp-reboot.service
check_pair host/systemd/vps-mcp-reboot.timer    /etc/systemd/system/vps-mcp-reboot.timer

# ── templated configs (only refreshed by re-running setupdone) ──────────────
check_pair host/opendkim/opendkim.conf.tmpl     /etc/opendkim.conf                subst_domain

# BIND paths differ between apt (Debian/Ubuntu) and dnf (RHEL family).
if command -v dnf >/dev/null 2>&1; then
    check_pair host/bind/named.conf.tmpl        /etc/named.conf
    _bind_local=/etc/named/named.conf.local
    _bind_zone_dir=/var/named
else
    _bind_local=/etc/bind/named.conf.local
    _bind_zone_dir=/etc/bind/zones
fi
_render_bind_local() {
    sed -e "s|__DOMAIN__|$DOMAIN|g" \
        -e "s|__BIND_ZONE_DIR__|$_bind_zone_dir|g" "$1"
}
check_pair host/bind/named.conf.local.tmpl      "$_bind_local"                    _render_bind_local

# dnf-automatic (dnf hosts only)
if command -v dnf >/dev/null 2>&1; then
    check_pair host/dnf/automatic.conf          /etc/dnf/automatic.conf
fi

# ── nginx: certbot rewrites the SSL lines in the live conf, so a raw diff is
#     always noisy. We still surface the file so drift in the non-TLS blocks
#     shows up; the note below reminds you to merge changes manually.
if [ -f /etc/nginx/sites-available/vps-mcp.conf ]; then
    _nginx_dst=/etc/nginx/sites-available/vps-mcp.conf
else
    _nginx_dst=/etc/nginx/conf.d/vps-mcp.conf
fi
echo "---- nginx (certbot manages TLS lines; diff below is expected to be noisy) ----"
check_pair nginx/vps-mcp.conf                   "$_nginx_dst"                     subst_domain

# ── nginx syntax check (live config) ─────────────────────────────────────────
# A content diff can't tell whether the assembled config actually parses: a
# stray or duplicated directive (e.g. a duplicate client_max_body_size) makes
# nginx refuse to load even though each file looks plausible on its own.
# `nginx -t` validates the whole live config the way nginx does at reload, so a
# broken config surfaces here instead of at the next (possibly automated) reload.
echo "---- nginx -t (live config syntax) ----"
if command -v nginx >/dev/null 2>&1; then
    if nginx -t >"$tmp/nginx-t" 2>&1; then
        echo "OK       nginx -t (configuration valid)"
    else
        echo "FAIL     nginx -t (configuration invalid)"
        sed 's/^/    /' "$tmp/nginx-t"
        status=1
    fi
else
    echo "SKIP     nginx -t (nginx not installed)"
fi

exit $status
