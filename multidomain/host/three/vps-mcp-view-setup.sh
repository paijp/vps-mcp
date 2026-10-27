#!/bin/sh
# https://github.com/paijp/vps-subdomain-mcp
# vps-mcp-view-setup.sh — prepare /run/vps-mcp/view for staging views.
#
# Run by vps-mcp-view.service before podman-restart.service. /run is a tmpfs,
# so after a reboot the shared view root and the per-stg mount points are
# gone; a dev container binds /run/vps-mcp/view/<staging hostname> and would
# fail to start without it. The root is made rshared so the read-only bind the
# OCI hook places on a mount point later (vps-mcp-stgview-hook.sh) propagates
# into the dev container (mounted there with rslave).
set -eu
V=/run/vps-mcp/view
mkdir -p "$V"
mountpoint -q "$V" || mount --bind "$V" "$V"
mount --make-rshared "$V"
podman ps -a --format '{{.Names}}' | sed -n 's/-web$//p' |
    grep -E -- '-stg\.|^stg\.' | while read -r h; do
        mkdir -p "$V/$h"
    done
