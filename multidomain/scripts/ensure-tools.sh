#!/bin/sh
# ensure-tools.sh CONTAINER — install the diagnostic tools listed in
# scripts/tools.sh that are missing from a running container. Run by
# `make <sub>.mcpupdate`, so containers created from an older image (which
# `mcpupdate` otherwise only refreshes the MCP app in) gain them in place.
#
# Only missing commands are installed, so the common case costs one `command -v`
# per tool inside the container and never invokes dnf. A failed install is
# reported but does NOT fail the run: refreshing the MCP app must not be blocked
# by a transient package-manager problem.

set -u

c=${1:-}
[ -n "$c" ] || { echo "usage: ensure-tools.sh CONTAINER" >&2; exit 2; }

dir=$(dirname "$0")
# shellcheck disable=SC1091
. "$dir/tools.sh"

missing=$(
    echo "$MCP_TOOLS" | while read -r cmd pkg; do
        [ -n "$cmd" ] || continue
        podman exec "$c" sh -c "command -v $cmd" >/dev/null 2>&1 && continue
        echo "$pkg"
    done | tr '\n' ' '
)

if [ -z "$(printf '%s' "$missing" | tr -d ' ')" ]; then
    printf "    %s: all diagnostic tools present\n" "$c"
    exit 0
fi

printf "    %s: installing missing tools: %s\n" "$c" "$missing"
if podman exec "$c" sh -c "dnf install -y $missing" >/dev/null; then
    printf "    %s: tools installed\n" "$c"
else
    printf "    %s: WARNING: install failed (%s). Run manually: podman exec %s dnf install -y %s\n" \
        "$c" "$missing" "$c" "$missing" >&2
fi
exit 0
