#!/bin/sh
# https://github.com/paijp/vps-mcp
# Regenerate mcp/package-lock.json (run on ONE machine, review, commit).
# Only versions published at least 7 days ago are chosen: malicious releases of
# hijacked packages are usually detected and pulled within days.
#   make npmlock                     # cooldown: versions older than 7 days
#   make npmlock BEFORE=2026-11-19   # override, e.g. to take an urgent fix now
set -e
cd "$(dirname "$0")/../mcp"
before="${BEFORE:-$(date -u -d '-7 days' +%F 2>/dev/null || date -u -v-7d +%F)}"
echo "npm-lock: resolving versions published before $before"
rm -f package-lock.json
npm install --package-lock-only --ignore-scripts --no-audit --no-fund --before="$before"
t=$(mktemp -d)
cp package.json package-lock.json "$t/"
(
    cd "$t"
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null
    echo "== resolved top-level versions"; npm ls --omit=dev --depth=0 || true
    echo "== packages with install scripts (blocked by --ignore-scripts): $(grep -c '"hasInstallScript": true' package-lock.json || true)"
    echo "== npm audit (known vulnerabilities)"; npm audit --omit=dev || true
    echo "== npm audit signatures (registry signatures / provenance)"; npm audit signatures || echo "npm-lock: WARNING: signature check could not run"
)
rm -rf "$t"
echo "npm-lock: review 'git diff mcp/package-lock.json', then commit."
