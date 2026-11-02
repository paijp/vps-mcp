#!/bin/sh
# https://github.com/paijp/vps-subdomain-mcp
# mask.sh — filter for output from a production container that a person may
# paste into a conversation with Claude (make <fqdn>.prodstatus, stg2prod).
# Masks what commonly identifies people, devices or secrets; it is a safety
# net, not a guarantee, so commands run on production should print counts,
# sizes and timestamps rather than data in the first place.
#   secrets      api_key=..., password: ..., token ..., secret=...  -> ***
#   e-mail       alice@example.com                                -> ***@example.com
#   IPv4         203.0.113.5                                      -> x.x.x.x
#                (127.0.0.1 and the container subnet 10.89.0.x kept)
#   long hex     16+ hex digits (keys, hashes, payloads)          -> <hex>
#   long digits  9+ digits (device IDs, phone numbers, ...)       -> <num>
#   query        ?a=b&c=d in request lines                        -> ?<query>
exec sed -E \
    -e 's/((api_?key|password|passwd|secret|token)[^=:[:space:]]*[=:] *["'\'']?)[^"'\''&[:space:]]+/\1***/Ig' \
    -e 's/[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+)/***@\1/g' \
    -e 's/(^|[^0-9.])127\.0\.0\.1([^0-9.]|$)/\1@@LO@@\2/g' \
    -e 's/(^|[^0-9.])10\.89\.0\.([0-9]{1,3})([^0-9.]|$)/\1@@CN-\2@@\3/g' \
    -e 's/(^|[^0-9.])10\.89\.0\.([0-9]{1,3})([^0-9.]|$)/\1@@CN-\2@@\3/g' \
    -e 's/(^|[^0-9.])[0-9]{1,3}(\.[0-9]{1,3}){3}([^0-9.]|$)/\1x.x.x.x\3/g' \
    -e 's/(^|[^0-9.])[0-9]{1,3}(\.[0-9]{1,3}){3}([^0-9.]|$)/\1x.x.x.x\3/g' \
    -e 's/@@LO@@/127.0.0.1/g; s/@@CN-([0-9]+)@@/10.89.0.\1/g' \
    -e 's/[0-9A-Fa-f]{16,}/<hex>/g' \
    -e 's/[0-9]{9,}/<num>/g' \
    -e 's/\?[^[:space:]"]+/?<query>/g'
