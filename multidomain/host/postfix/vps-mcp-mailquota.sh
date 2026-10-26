#!/bin/sh
# https://github.com/paijp/vps-subdomain-mcp
#
# vps-mcp-mailquota.sh — Postfix policy service: per-container daily mail quota
#
# Run by spawn(8) (see "make install-services"), one process per SMTP
# connection, speaking the Postfix policy delegation protocol on stdin/stdout.
# Hooked into smtpd_end_of_data_restrictions, so it is asked once per message.
#
# Each container relays from its own 10.89.0.0/24 address; messages are
# counted per client address per day (local time). Once MAILQUOTA_DAILY
# messages have been accepted, further messages are rejected with 5xx so the
# sender gets an immediate, permanent error. The per-minute rate limit is
# done by Postfix anvil (smtpd_client_message_rate_limit), not here.
#
# Staging containers of a create3 set (container name *-staging.<domain>-web or
# staging.<domain>-web, looked up by client address in /run/vps-mcp/containers)
# additionally get "BCC stgcapture+<name>@localhost": the message is still
# delivered normally, and a copy lands in /var/spool/vps-mcp-stgmail/ for
# vps-mcp-stgmail.path to hand to the matching dev container. The decision is
# made here, before queueing, so no copy of any other container's mail (e.g.
# production mail with customer data) is ever written on the host.
#
# State: $STATE_DIR/<client_address> containing "YYYYMMDD COUNT".

MAILQUOTA_DAILY=${MAILQUOTA_DAILY:-200}
STATE_DIR=${STATE_DIR:-/var/lib/vps-mcp-mailquota}
CONTAINERS=${CONTAINERS:-/run/vps-mcp/containers}

decide() {
    case $1 in
        10.89.0.*) ;;
        *) echo "action=DUNNO"; return ;;   # not a container — no quota
    esac
    f="$STATE_DIR/$1"
    today=$(date +%Y%m%d)
    (
        flock 9
        day=; count=0
        [ -s "$f" ] && read -r day count < "$f"
        [ "$day" = "$today" ] || count=0
        if [ "$count" -ge "$MAILQUOTA_DAILY" ]; then
            echo "action=REJECT 5.7.1 Daily mail quota ($MAILQUOTA_DAILY messages) exceeded for $1"
        else
            echo "$today $((count + 1))" > "$f.tmp" && mv "$f.tmp" "$f"
            name=$(awk -F '\t' -v ip="$1" '$2 == ip { print $1; exit }' "$CONTAINERS" 2>/dev/null)
            case $name in
                *-staging.*-web|staging.*-web) echo "action=BCC stgcapture+$name@localhost" ;;
                *) echo "action=DUNNO" ;;
            esac
        fi
    ) 9>>"$f.lock"
}

client=
while IFS= read -r line; do
    line=${line%"$(printf '\r')"}
    case $line in
        client_address=*) client=${line#client_address=} ;;
        "")
            decide "$client"
            echo
            client=
            ;;
    esac
done
