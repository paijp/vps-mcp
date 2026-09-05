#!/bin/sh
# ensure-tools.sh — install the diagnostic tools listed in scripts/tools.sh that
# are missing from this host. Run by `make mcpupdate`, so an already-set-up host
# picks them up without re-running the full setup.
#
# Only missing commands are installed, so the common case costs one `command -v`
# per tool and touches no package manager. A failed install is reported but does
# NOT fail the run: refreshing the MCP app must not be blocked by a transient
# package-manager problem.

set -u

dir=$(dirname "$0")
# shellcheck disable=SC1091
. "$dir/tools.sh"

if command -v dnf >/dev/null 2>&1; then
    col=2; install="dnf install -y"
elif command -v apt-get >/dev/null 2>&1; then
    col=3; install="apt-get install -y"
else
    echo "ensure-tools: no supported package manager; skipping tool check." >&2
    exit 0
fi

missing=$(
    echo "$MCP_TOOLS" | while read -r cmd dnfpkg aptpkg; do
        [ -n "$cmd" ] || continue
        command -v "$cmd" >/dev/null 2>&1 && continue
        if [ "$col" = 2 ]; then echo "$dnfpkg"; else echo "$aptpkg"; fi
    done | tr '\n' ' '
)

if [ -z "$(printf '%s' "$missing" | tr -d ' ')" ]; then
    printf "ensure-tools: all diagnostic tools present.\n"
    exit 0
fi

printf "ensure-tools: installing missing tools: %s\n" "$missing"
# apt refuses to fetch against a stale index (the setup target runs `apt-get
# update` itself; mcpupdate may run long after). dnf refreshes on its own.
[ "$col" = 3 ] && apt-get update >/dev/null 2>&1
# shellcheck disable=SC2086
if $install $missing; then
    printf "ensure-tools: done.\n"
else
    printf "ensure-tools: WARNING: install failed (%s). Run it manually: %s %s\n" \
        "$missing" "$install" "$missing" >&2
fi
exit 0
