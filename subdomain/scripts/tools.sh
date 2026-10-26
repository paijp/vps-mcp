#!/bin/sh
# tools.sh — the extra command-line tools every container is expected to carry,
# as the single source of truth shared by scripts/ensure-tools.sh (which
# installs the missing ones during `make mcpupdate`), scripts/check-installed.sh
# (which reports them) and container/Containerfile (which bakes them into the
# image). Sourced, not executed.
#
# These are what exec_command reaches for when diagnosing a live container; the
# Rocky base image ships few of them. One entry per line:
#
#   <command>  <package>
#
# The command is what is actually tested — `sqlite3` comes from the `sqlite`
# package and `ps` from `procps-ng`, so package names alone would not tell you
# whether the binary is there. Containers are always Rocky Linux (dnf), so
# unlike the full edition there is only one package column.

MCP_TOOLS='
ss       iproute
ps       procps-ng
lsof     lsof
sqlite3  sqlite
jq       jq
'
