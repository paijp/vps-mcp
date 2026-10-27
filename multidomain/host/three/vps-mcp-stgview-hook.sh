#!/bin/sh
# https://github.com/paijp/vps-subdomain-mcp
# vps-mcp-stgview-hook.sh poststart|poststop — OCI hook, run for EVERY
# container start/stop (hooks.d/vps-mcp-stgview-*.json, "always").
#
# Acts only on staging containers, decided by hostname (= container name
# without "-web"): <label>-stg.<domain> or stg.<domain>.
#   poststart  bind the container's rootfs READ-ONLY at /run/vps-mcp/view/<host>
#              (one `mount --bind -o ro`: the mount is read-only before it
#              becomes visible, so the copy propagated into the dev container
#              is read-only too — a bind followed by a ro remount is not)
#              and, on top of it, the container's /var/log/journal: Podman
#              mounts its own tmpfs (or the journal volume) there in systemd
#              mode, which a bind of the rootfs alone does not include
#   poststop   remove those binds, so a stopped or deleted staging container is
#              never shown with stale content
# Every action is logged: journalctl -t vps-mcp-stgview
#
# Must never fail, and must not call podman (the hook runs while Podman holds
# its lock): a hook error must not affect any container.
V=/run/vps-mcp/view
state=$(cat)
bundle=$(printf '%s' "$state" | jq -r .bundle 2>/dev/null)
host=$(jq -r .hostname "$bundle/config.json" 2>/dev/null)
case $host in
    *-stg.*|stg.*) ;;
    *) exit 0 ;;
esac
case $host in */*|.*) exit 0 ;; esac
id=$(printf '%s' "$state" | jq -r .id 2>/dev/null | cut -c1-12)
case ${1:-} in
poststart)
    root=$(jq -r .root.path "$bundle/config.json" 2>/dev/null)
    pid=$(printf '%s' "$state" | jq -r .pid 2>/dev/null)
    mkdir -p "$V/$host"
    mountpoint -q "$V/$host" && umount -R "$V/$host"
    if [ -d "$root" ] && mount --bind -o ro "$root" "$V/$host"; then r=ok; else r=FAILED; fi
    j=/proc/$pid/root/var/log/journal
    if [ $r = ok ] && [ -d "$j" ] && [ -d "$V/$host/var/log/journal" ]; then
        if mount --bind -o ro "$j" "$V/$host/var/log/journal"; then r="$r journal=ok"; else r="$r journal=FAILED"; fi
    fi ;;
poststop)
    if mountpoint -q "$V/$host"; then
        if umount -R "$V/$host"; then r=ok; else r=FAILED; fi
    else
        r=not-mounted
    fi ;;
*)  exit 0 ;;
esac
logger -t vps-mcp-stgview "$1 $host-web id=$id: $r"
exit 0
