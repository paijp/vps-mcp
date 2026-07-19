#!/bin/sh
# check-installed.sh — compare files installed by `make ...setupdone` /
# `make install-services` / `make sshsec.done` against the current checkout,
# so drift in configs that aren't refreshed by `mcpupdate` (which only touches
# the in-container MCP app) becomes visible.
#
# Reports one line per file:
#   OK       <path>                   installed matches repo
#   DIFFER   <path>  (source: <src>)  installed differs from repo
#   MISSING  <path>  (source: <src>)  installed file not present
#   SKIP     <path>  <reason>
#
# Exit 0 if everything is OK/SKIP, 1 if any file is DIFFER or MISSING.
#
# Run from the `subdomain/` directory (the Makefile's `check` target does this).

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

subst_domain() { sed "s|__DOMAIN__|$DOMAIN|g" "$1"; }

# nftables template substitutes the runtime UIDs of the proxy users; replay
# that so a raw diff isn't dominated by UID lines.
render_nft() {
    uid443=$(id -u proxy443 2>/dev/null || echo __UID_PROXY443__)
    uid80=$(id -u proxy80  2>/dev/null || echo __UID_PROXY80__)
    uid_postfix=$(id -u postfix 2>/dev/null || echo __UID_POSTFIX__)
    sed -e "s|__UID_PROXY443__|$uid443|g" \
        -e "s|__UID_PROXY80__|$uid80|g" \
        -e "s|__UID_POSTFIX__|$uid_postfix|g" "$1"
}

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

# ── proxy sockets/services (install-services) ────────────────────────────────
check_pair host/systemd/vps-proxy443.socket   /etc/systemd/system/vps-proxy443.socket
check_pair host/systemd/vps-proxy443.service  /etc/systemd/system/vps-proxy443.service
check_pair host/systemd/vps-proxy80.socket    /etc/systemd/system/vps-proxy80.socket
check_pair host/systemd/vps-proxy80.service   /etc/systemd/system/vps-proxy80.service

# ── weekly reboot units ──────────────────────────────────────────────────────
check_pair host/systemd/vps-mcp-reboot.service /etc/systemd/system/vps-mcp-reboot.service
check_pair host/systemd/vps-mcp-reboot.timer   /etc/systemd/system/vps-mcp-reboot.timer

# ── nftables ─────────────────────────────────────────────────────────────────
check_pair host/nftables/vps-mcp.nft.tmpl      /etc/nftables.d/vps-mcp.nft        render_nft

# ── opendkim ────────────────────────────────────────────────────────────────
check_pair host/opendkim/opendkim.conf.tmpl    /etc/opendkim.conf                 subst_domain

# ── BIND (paths differ between apt and dnf) ──────────────────────────────────
if command -v dnf >/dev/null 2>&1; then
    check_pair host/bind/named.conf.tmpl       /etc/named.conf
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
check_pair host/bind/named.conf.local.tmpl     "$_bind_local"                     _render_bind_local

# ── dnf-automatic (dnf hosts only) ───────────────────────────────────────────
if command -v dnf >/dev/null 2>&1; then
    check_pair host/dnf/automatic.conf         /etc/dnf/automatic.conf
fi

# ── optional sshsec.done bits (only reported if installed) ───────────────────
if [ -e /etc/ssh/sshd_config.d/00-vps-mcp-hardening.conf ]; then
    check_pair host/ssh/00-vps-mcp-hardening.conf \
                                                /etc/ssh/sshd_config.d/00-vps-mcp-hardening.conf
fi
if [ -e /etc/fail2ban/jail.d/00-vps-mcp.conf ]; then
    check_pair host/fail2ban/jail.d/00-vps-mcp.conf \
                                                /etc/fail2ban/jail.d/00-vps-mcp.conf
fi

# ── container image staleness (informational) ────────────────────────────────
# The MCP app inside each container is refreshed in place by `make mcpupdate`,
# but the image itself only picks up repo changes when `make image` is re-run.
# Compare the repo's container/mcp/{index.mjs,package.json} against the copies
# baked into the image so image drift is visible too.
if command -v podman >/dev/null 2>&1 && podman image exists "${IMAGE:-vps-mcp:latest}" 2>/dev/null; then
    for f in container/mcp/index.mjs container/mcp/package.json; do
        base=$(basename "$f")
        baked="$tmp/baked.$base"
        if podman run --rm --entrypoint cat "${IMAGE:-vps-mcp:latest}" "/opt/mcp/$base" > "$baked" 2>/dev/null; then
            if cmp -s "$f" "$baked"; then
                echo "OK       image:${IMAGE:-vps-mcp:latest}:/opt/mcp/$base"
            else
                echo "DIFFER   image:${IMAGE:-vps-mcp:latest}:/opt/mcp/$base  (source: $f) — run 'make image' to rebuild"
                status=1
            fi
        fi
    done
fi

exit $status
