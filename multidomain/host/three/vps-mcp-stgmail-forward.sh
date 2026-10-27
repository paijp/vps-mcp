#!/bin/sh
# https://github.com/paijp/vps-subdomain-mcp
# vps-mcp-stgmail-forward.sh — hand staging mail copies to the dev container.
#
# Run (root) by vps-mcp-stgmail.service whenever vps-mcp-stgmail.path sees mail
# in /var/spool/vps-mcp-stgmail/new/. The copies come from the mail policy
# (BCC stgcapture+<staging container>@localhost); X-Original-To names the
# staging container, and the dev container is the same name with "-stg"
# replaced by "-dev" (stg.<domain> → dev.<domain>). Each copy is written
# into the dev container as /srv/stg-mail/<date>-<id>.eml and removed here. If
# the dev container is not running, the copy is moved to hold/, which
# vps-mcp-stgmail-retry.timer moves back every minute (leaving it in new/
# would retrigger the path unit in a tight loop until systemd gives up).
spool=/var/spool/vps-mcp-stgmail
mkdir -p "$spool/hold"
for f in "$spool"/new/*; do
    [ -f "$f" ] || continue
    stg=$(sed -n '/^$/q; s/^X-Original-To: stgcapture+\([A-Za-z0-9.-]*-web\)@localhost.*/\1/p' "$f" | head -n 1)
    case $stg in
        *-stg.*-web|stg.*-web) ;;
        *) rm -f "$f"; continue ;;
    esac
    dev=$(printf '%s' "$stg" | sed -e 's/-stg\./-dev./' -e 's/^stg\./dev./')
    if ! podman container exists "$dev"; then
        logger -t vps-mcp-stgmail "no dev container $dev for $stg; dropped $(basename "$f")"
        rm -f "$f"; continue
    fi
    name="$(date -r "$f" +%Y-%m-%d-%H%M%S)-$(basename "$f" | cut -d. -f1-2).eml"
    if podman exec -i "$dev" sh -c "mkdir -p /srv/stg-mail && cat > '/srv/stg-mail/$name' && find /srv/stg-mail -name '*.eml' -mtime +14 -delete" < "$f"; then
        rm -f "$f"
    else
        mv "$f" "$spool/hold/"
    fi
done
exit 0
