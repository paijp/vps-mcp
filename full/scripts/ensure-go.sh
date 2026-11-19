#!/bin/sh
# https://github.com/paijp/vps-mcp
# Make sure a Go toolchain (>= 1.22, for net/http method routing) is present to
# build the MCP server. Installs the distribution's golang package if `go` is
# missing; fails with a clear message if the available one is too old.
set -e
# go needs HOME for its caches; it is empty under a service or a connector.
: "${HOME:=/root}"; export HOME
if ! command -v go >/dev/null 2>&1; then
    if command -v dnf >/dev/null 2>&1; then dnf install -y golang
    elif command -v apt-get >/dev/null 2>&1; then apt-get install -y golang-go
    else echo "ensure-go: no supported package manager; install Go >= 1.22" >&2; exit 1; fi
fi
v=$(go env GOVERSION | sed 's/^go//')
major=${v%%.*}; rest=${v#*.}; minor=${rest%%.*}
if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 22 ]; }; then
    echo "ensure-go: Go $v is too old (need >= 1.22); install a newer Go and re-run" >&2
    exit 1
fi
