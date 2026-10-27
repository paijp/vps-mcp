#!/bin/sh
# names3.sh FQDN — print "<production> <staging> <dev>" hostnames of the
# create3 set whose production hostname is FQDN:
#   shop.example.org  →  shop.example.org  shop-stg.example.org  shop-dev.example.org
#   example.org       →  example.org       stg.example.org       dev.example.org
# (a registered domain apex — see /etc/vps-mcp/domains — has no label to
# extend, so its staging/dev take the reserved labels "stg" and "dev").
p=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
[ -n "$p" ] || { echo "usage: names3.sh FQDN" >&2; exit 2; }
if grep -qxF "$p" /etc/vps-mcp/domains 2>/dev/null; then
    echo "$p stg.$p dev.$p"
else
    echo "$p ${p%%.*}-stg.${p#*.} ${p%%.*}-dev.${p#*.}"
fi
