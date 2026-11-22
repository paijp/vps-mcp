#!/bin/sh
# https://github.com/paijp/vps-mcp
# vps-mcp-adopt.sh — run by mcp-server.service before every start
# (ExecStartPre). Adopts an MCP server binary that host maintenance staged in
# the inbox, so a new build takes effect at this container's next natural
# restart (the host's weekly reboot, a crash, or a manual restart) instead of
# the host replacing the running binary.
#
#   inbox   /var/lib/vps-mcp/incoming/{vps-mcp,main.go}   (placed by `make mcpstage`)
#   live    /opt/mcp/vps-mcp, /opt/mcp/main.go
#   backup  /opt/mcp/vps-mcp.prev                         (the binary it replaced)
#   ident   /opt/mcp/vps-mcp.ident                        (what /opt/mcp/vps-mcp is)
#
# The live binary is never executed to identify it: a build older than
# -version support would start serving instead (and hold the start up).
# Only the staged binary is run, with a timeout, and its identity is then
# recorded in the ident file.
#
# Every outcome is logged to this unit's journal. It always exits 0: a bad
# staged file must never keep mcp-server from starting on the current binary.
inbox=/var/lib/vps-mcp/incoming
live=/opt/mcp
[ -e "$inbox/vps-mcp" ] || exit 0

ident() { timeout 10 "$1" -version 2>/dev/null | sed -n 's/^vps-mcp //p'; }

new=$(ident "$inbox/vps-mcp")
if [ -z "$new" ]; then
    mv -f "$inbox/vps-mcp" "$inbox/vps-mcp.rejected" 2>/dev/null
    echo "vps-mcp-adopt: staged binary does not run (-version failed); kept the current one, moved it to $inbox/vps-mcp.rejected"
    exit 0
fi
cur=$(cat "$live/vps-mcp.ident" 2>/dev/null); [ -n "$cur" ] || cur="unidentified (older build)"
if [ "$cur" = "$new" ]; then
    rm -f "$inbox/vps-mcp" "$inbox/main.go"
    echo "vps-mcp-adopt: staged binary is the one already running ($new); nothing to do"
    exit 0
fi
cp -p "$live/vps-mcp" "$live/vps-mcp.prev" 2>/dev/null
if install -m 755 "$inbox/vps-mcp" "$live/vps-mcp.new" && mv -f "$live/vps-mcp.new" "$live/vps-mcp"; then
    [ -e "$inbox/main.go" ] && install -m 644 "$inbox/main.go" "$live/main.go"
    printf '%s\n' "$new" > "$live/vps-mcp.ident"
    rm -f "$inbox/vps-mcp" "$inbox/main.go"
    echo "vps-mcp-adopt: adopted the binary staged by host maintenance: $cur -> $new (previous kept as $live/vps-mcp.prev)"
else
    rm -f "$live/vps-mcp.new"
    echo "vps-mcp-adopt: could not install the staged binary; kept the current one ($cur)"
fi
exit 0
