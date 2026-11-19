#!/bin/sh
# https://github.com/paijp/vps-mcp
# Install the MCP app's dependencies exactly as pinned in package-lock.json.
#   - npm ci: installs only the versions (and integrity hashes) in the lockfile,
#     never "the newest in range" — every host gets the reviewed tree.
#   - --ignore-scripts: no package install/postinstall script runs (as root).
#     None of the current dependencies needs one.
# Builds in a temporary directory and swaps node_modules in only on success, so
# a registry failure leaves the previous, working tree in place.
# Usage: sh mcp-npm-ci.sh [/opt/mcp]      (or: podman exec -i C sh -s < this)
set -e
cd "${1:-/opt/mcp}"
test -f package-lock.json || { echo "mcp-npm-ci: package-lock.json missing in $PWD" >&2; exit 1; }
t=$(mktemp -d "$PWD/.npmci.XXXXXX")
cp package.json package-lock.json "$t/"
if (cd "$t" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null); then
    rm -rf node_modules.old
    if [ -d node_modules ]; then mv node_modules node_modules.old; fi
    mv "$t/node_modules" node_modules
    rm -rf node_modules.old "$t"
    echo "mcp-npm-ci: dependencies installed from package-lock.json"
else
    rm -rf "$t"
    echo "mcp-npm-ci: npm ci failed; previous node_modules kept" >&2
    exit 1
fi
