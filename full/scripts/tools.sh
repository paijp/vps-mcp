#!/bin/sh
# tools.sh — the extra command-line tools this host is expected to carry, as the
# single source of truth shared by scripts/ensure-tools.sh (which installs the
# missing ones during `make mcpupdate`) and scripts/check-installed.sh (which
# reports them). Sourced, not executed.
#
# These are what exec_command reaches for when diagnosing a live host; a minimal
# cloud image ships few of them. One entry per line:
#
#   <command>  <dnf package>  <apt package>
#
# The command is what is actually tested — on RHEL `sqlite3` comes from the
# `sqlite` package and `ps` from `procps-ng`, so package names alone would not
# tell you whether the binary is there.

MCP_TOOLS='
ss       iproute    iproute2
ps       procps-ng  procps
lsof     lsof       lsof
sqlite3  sqlite     sqlite3
jq       jq         jq
'
