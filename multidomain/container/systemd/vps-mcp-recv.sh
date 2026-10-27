#!/bin/bash
# https://github.com/paijp/vps-subdomain-mcp
# vps-mcp-recv.sh MODE — receive a git bundle of HEAD on stdin into /srv/app.
# Run by the host (make <fqdn>.dev2stg / .stg2prod) through `podman exec -i`.
#
#   stg      follow whatever commit was sent (it may move backwards, e.g. for a
#            hotfix branched from prod/main); refuse if /srv/app has
#            local changes, so a hand edit on staging is never overwritten.
#   prod     fast-forward only, and refuse local changes: production only ever
#            receives what staging ran, on top of what it already runs.
#
# Prints the new HEAD on success.
set -euo pipefail

mode=${1:-}
case $mode in
    stg|prod) ;;
    *) echo "usage: vps-mcp-recv.sh stg|prod  < bundle" >&2; exit 2 ;;
esac

cd /srv/app
if [[ -n "$(git status --porcelain)" ]]; then
    echo "vps-mcp-recv: /srv/app on $(hostname) has local changes; aborting" >&2
    git status --short >&2
    exit 1
fi

bundle=$(mktemp /var/tmp/vps-mcp-recv.XXXXXX)
trap 'rm -f "$bundle"' EXIT
cat > "$bundle"
git bundle verify -q "$bundle" >/dev/null 2>&1 ||
    { echo "vps-mcp-recv: received data is not a valid git bundle" >&2; exit 1; }

if [[ $mode == stg ]]; then
    git fetch -q "$bundle" HEAD
    git reset -q --hard FETCH_HEAD
else
    git -c advice.diverging=false pull -q --ff-only "$bundle" HEAD
fi
git rev-parse HEAD
