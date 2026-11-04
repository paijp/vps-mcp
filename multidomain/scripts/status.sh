#!/bin/bash
# https://github.com/paijp/vps-subdomain-mcp
#
# status.sh [NAME] — where each hostname of this host's domains leads, one
# line per port (make status / make <name>.status). Read-only.
#
#   (pa-i.jp.dnsdone->)(DNS->)203.0.113.1:443 -> a.pa-i.jp-web -> CERT+MCP
#
#   (<domain>.dnsdone->)   this host's zone (BIND here) points at that address;
#                          "dnsdone*->" when the wildcard answers
#   (DNS->)                a public resolver (8.8.8.8) points at that address
#   CERT / CERT+MCP        443 terminated here with a Let's Encrypt
#                          certificate for the name (+ the MCP server runs)
#   HTTPS-REDIRECT         port 80 redirects to HTTPS
#   -> IP:port             forwarded to the old server (forward mode, or
#                          app.d/forward.conf after unforward)
#   (... IP)               the old server it forwarded to once (kept in the
#                          container's /etc/vps-mcp/forward-ip; delete that
#                          file to drop the note)
#
# Names shown: every container, every A record in this host's zones, and
# every name in a container's cert-names. Staging and development containers
# show port 443 only. Per-name exceptions (plain-http server blocks, other
# app.d locations) are not shown.
set -u

. /etc/vps-mcp/host.env 2>/dev/null || { echo "status: /etc/vps-mcp/host.env not found" >&2; exit 1; }
H=$IP
DOMAINS=$(cat /etc/vps-mcp/domains 2>/dev/null | tr 'A-Z' 'a-z')
ONLY=${1:-}
RESOLVER=${RESOLVER:-8.8.8.8}

ipv4() { grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | paste -sd, -; }
zone_a() { dig +short +time=3 +tries=1 @127.0.0.1 A "$1" 2>/dev/null | ipv4; }
pub_a()  { dig +short +time=5 +tries=1 @"$RESOLVER" A "$1" 2>/dev/null | ipv4; }

# domain_of NAME — the longest registered domain NAME belongs to.
domain_of() {
    local n=$1 d best=
    for d in $DOMAINS; do
        if [[ $n == "$d" || $n == *."$d" ]] && (( ${#d} > ${#best} )); then best=$d; fi
    done
    echo "$best"
}

# Explicit A records (owner names) of a domain's zone file.
zone_owners() {
    local d=$1 f=$BIND_ZONE_DIR/$1.zone
    [[ -f $f ]] || return 0
    awk -v d="$d" '
        /^[ \t;$]/ || /^$/ { next }
        { o = tolower($1); t = "" }
        { for (i = 2; i <= NF; i++) { u = toupper($i); if (u ~ /^[0-9]+$/ || u == "IN") continue; t = u; break } }
        t != "A" { next }
        o == "*" || o == "ns1" { next }
        o == "@" || o == d "." { print d; next }
        o ~ /\.$/ { sub(/\.$/, "", o); print o; next }
        { print o "." d }
    ' "$f"
}

explicit_in_zone() {  # explicit_in_zone NAME DOMAIN
    zone_owners "$2" | grep -qxF "$1"
}

# ── container facts, one podman exec each ──────────────────────────────────
declare -A ROLE FWD STREAM HTTP80 APPFWD SANS MCP
CONTAINERS=$(podman ps --format '{{.Names}}' 2>/dev/null | sed -n 's/-web$//p' | tr '\n' ' ')
for c in $CONTAINERS; do
    out=$(podman exec "$c-web" sh -c '
        echo "role=$(sed -n "s/^ROLE=//p" /etc/vps-mcp-env 2>/dev/null)"
        echo "fwd=$(cat /etc/vps-mcp/forward-ip 2>/dev/null)"
        [ -f /etc/nginx/stream.d/forward.conf ] && echo stream=1
        [ -f /etc/nginx/http80.d/forward.conf ] && echo http80=1
        echo "appfwd=$(sed -n "s|^[^#]*proxy_pass https\{0,1\}://\([0-9.]*\).*|\1|p" /etc/nginx/app.d/forward.conf 2>/dev/null | head -n1)"
        crt=$(sed -n "s|^[^#]*ssl_certificate[ \t][ \t]*\(/etc/letsencrypt/[^;]*\);.*|\1|p" /etc/nginx/ssl-cert.conf 2>/dev/null | head -n1)
        if [ -n "$crt" ] && openssl x509 -checkend 0 -noout -in "$crt" >/dev/null 2>&1; then
            echo "sans=$(openssl x509 -noout -ext subjectAltName -in "$crt" 2>/dev/null | tr "," "\n" | sed -n "s/ *DNS://p" | tr "\n" " ")"
        fi
        systemctl is-active --quiet mcp-server 2>/dev/null && echo mcp=1
        sed -e "s/#.*//" -e "/^[ \t]*$/d" /etc/vps-mcp/cert-names 2>/dev/null | awk "{print \"certname=\" \$1}"
    ' 2>/dev/null)
    ROLE[$c]=$(sed -n 's/^role=//p' <<<"$out")
    FWD[$c]=$(sed -n 's/^fwd=//p' <<<"$out")
    STREAM[$c]=$(grep -qx stream=1 <<<"$out" && echo 1)
    HTTP80[$c]=$(grep -qx http80=1 <<<"$out" && echo 1)
    APPFWD[$c]=$(sed -n 's/^appfwd=//p' <<<"$out")
    SANS[$c]=" $(sed -n 's/^sans=//p' <<<"$out") "
    MCP[$c]=$(grep -qx mcp=1 <<<"$out" && echo 1)
    CERTNAMES+=" $(sed -n 's/^certname=//p' <<<"$out" | tr '\n' ' ')"
done

# container_for NAME DOMAIN — the container the proxies send NAME to.
container_for() {
    local n=$1 d=$2 p
    [[ " $CONTAINERS " == *" $n "* ]] && { echo "$n"; return; }
    if [[ $n != "$d" ]]; then
        p=${n%."$d"}; p=${p##*.}.$d
        [[ " $CONTAINERS " == *" $p "* ]] && { echo "$p"; return; }
    fi
    [[ " $CONTAINERS " == *" $d "* ]] && echo "$d"
}

# ── the names, in display order ────────────────────────────────────────────
names=$( { printf '%s\n' $CONTAINERS; for d in $DOMAINS; do zone_owners "$d"; done; printf '%s\n' ${CERTNAMES:-}; } |
    tr 'A-Z' 'a-z' | sort -u)
order=$(for n in $names; do
    d=$(domain_of "$n"); [[ -n $d ]] || continue
    p=${n%"$d"}; p=${p%.}
    role=0 base=$p
    case $p in
        stg) base= role=1 ;; dev) base= role=2 ;;
        *-stg|*-stg.*) base=${p/-stg/}; role=1 ;;
        *-dev|*-dev.*) base=${p/-dev/}; role=2 ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$d" "${base:+1}" "$base" "$role" "$n"
done | sort -t$'\t' -k1,1 -k2,2 -k3,3 -k4,4n | cut -f5)

if [[ -n $ONLY ]]; then
    set3=" $(sh "$(dirname "$0")/names3.sh" "$ONLY" 2>/dev/null) $ONLY "
    order=$(for n in $order; do [[ $set3 == *" $n "* ]] && echo "$n"; done)
fi

for n in $order; do
    d=$(domain_of "$n")
    Z=$(zone_a "$n"); P=$(pub_a "$n")
    zl="$d.dnsdone"; [[ -n $Z ]] && ! explicit_in_zone "$n" "$d" && zl="$d.dnsdone*"
    shown=" "
    lab() {  # lab IP — L = the labels of the sources pointing at IP; marks it shown
        L=
        [[ -n $Z && $Z == "$1" ]] && L="($zl->)"
        [[ -n $P && $P == "$1" ]] && L="$L(DNS->)"
        shown+="$1 "
    }
    echo
    echo "$n:"
    c=$(container_for "$n" "$d")
    if [[ -n $c ]]; then
        cw="$c-web" fwd=${FWD[$c]} role=${ROLE[$c]}
        if [[ $role != stg && $role != dev ]]; then
            lab "$H"; line="    $L$H:80 -> $cw -> "
            if [[ -n ${HTTP80[$c]} && -n $fwd ]]; then lab "$fwd"; line+="$L$fwd:80"; else line+="HTTPS-REDIRECT"; fi
            echo "$line"
        fi
        lab "$H"; line="    $L$H:443 -> $cw"
        if [[ -n ${STREAM[$c]} && -n $fwd ]]; then
            lab "$fwd"; line+=" -> $L$fwd:443"
        else
            if [[ ${SANS[$c]} == *" $n "* ]]; then
                if [[ -n ${MCP[$c]} ]]; then line+=" -> CERT+MCP"; else line+=" -> CERT"; fi
            fi
            if [[ -n ${APPFWD[$c]} ]]; then lab "${APPFWD[$c]}"; line+=" -> $L${APPFWD[$c]}:443"; fi
        fi
        # The old server it forwarded to once (forward-ip outlives unforward),
        # when no line above still goes there.
        [[ -n $fwd && $shown != *" $fwd "* ]] && line+="  (... $fwd)"
        echo "$line"
    fi
    # Whatever the zone or public DNS points at that is not on a line yet.
    if [[ -n $Z && $shown != *" $Z "* ]]; then
        lab "$Z"; echo "    $L$Z"
    fi
    if [[ -n $P && $shown != *" $P "* ]]; then
        echo "    (DNS->)$P"
    fi
done
