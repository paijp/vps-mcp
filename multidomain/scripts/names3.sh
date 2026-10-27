#!/bin/sh
# names3.sh FQDN — print "<production> <staging> <dev>" hostnames of the
# create3 set whose production hostname is FQDN:
#   shop.ksy.jp  →  shop.ksy.jp  shop-stg.ksy.jp  shop-dev.ksy.jp
#   ksy.jp       →  ksy.jp       stg.ksy.jp       dev.ksy.jp
# (a registered domain apex — see /etc/vps-mcp/domains — has no label to
# extend, so its staging/dev take the reserved labels "stg" and "dev").
p=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
[ -n "$p" ] || { echo "usage: names3.sh FQDN" >&2; exit 2; }
if grep -qxF "$p" /etc/vps-mcp/domains 2>/dev/null; then
    echo "$p stg.$p dev.$p"
else
    echo "$p ${p%%.*}-stg.${p#*.} ${p%%.*}-dev.${p#*.}"
fi
