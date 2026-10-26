#!/bin/sh
# https://github.com/paijp/vps-subdomain-mcp
# vps-mcp-containers.sh — publish the container name / IP list.
#
# Run by vps-mcp-containers.service (root). Copies each batch printed by
# `list-containers --loop 5` ("name<TAB>ip<TAB>state" lines, then "---") to
# /run/vps-mcp/containers, replacing it atomically and world-readable, so the
# mail policy service (user vpsmailq, no Podman access) can map a client
# address to a container name.
set -u
dir=/run/vps-mcp
mkdir -p "$dir"
: > "$dir/containers.tmp"
/usr/local/sbin/list-containers --loop 5 | while IFS= read -r line; do
    if [ "$line" = "---" ]; then
        chmod 644 "$dir/containers.tmp"
        mv "$dir/containers.tmp" "$dir/containers"
        : > "$dir/containers.tmp"
    else
        printf '%s\n' "$line" >> "$dir/containers.tmp"
    fi
done
