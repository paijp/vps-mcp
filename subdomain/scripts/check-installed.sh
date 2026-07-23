#!/bin/sh
# check-installed.sh — compare files installed by `make ...setupdone` /
# `make install-services` / `make sshsec.done` (and the files baked into each
# running container) against the current checkout, so drift in configs that
# aren't refreshed by `mcpupdate` (which only touches the in-container MCP app)
# becomes visible.
#
# Reports one line per file:
#   OK       <path>                   installed matches repo
#   DIFFER   <path>  (source: <src>)  installed differs from repo
#   MISSING  <path>  (source: <src>)  installed file not present
#   SKIP     <path>  <reason>
#   FAIL     <path>  <reason>         a live check (e.g. `nginx -t`) failed
#
# Exit 0 if everything is OK/SKIP, 1 if any file is DIFFER / MISSING / FAIL.
#
# Modes (driven by the Makefile targets — run from the `subdomain/` directory):
#   make check              summary: one status line per file. The nginx configs
#                           also print HOW they differ, but only for the repo's
#                           own content — location blocks an operator adds are
#                           ignored, so the output isn't flooded by local
#                           customisations (only real drift in shipped content,
#                           the kind that silently takes the server down, shows).
#   make checkall           verbose: print the diff for EVERY differing file
#                           (nginx configs then show their added blocks too).
#   make <container>.check  verbose, scoped to one container (e.g. alice.check
#                           → alice-web); skips the host-side checks.
#
# Environment:
#   VERBOSE=1   print the diff body for every DIFFER (set by `checkall` and the
#               per-container target). Default 0 = summary.
#   $1          optional container name; when given, only that container is
#               checked and the host-side / image checks are skipped.

set -u

VERBOSE=${VERBOSE:-0}
ONLY=${1:-}   # optional container name (e.g. alice-web); empty = check everything

if [ ! -f /etc/vps-mcp/host.env ]; then
    echo "Error: /etc/vps-mcp/host.env not found — run setupdone first." >&2
    exit 2
fi
# shellcheck disable=SC1091
. /etc/vps-mcp/host.env

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
status=0

# show_diff EXPECTED ACTUAL — print an indented, truncated unified diff.
show_diff() { diff -u "$1" "$2" | sed 's/^/    /' | head -n 40; }

# filtered_hunks DIFF_FILE — read a `diff -u` file and print only the hunks that
# remove or change a line from the expected (repo) side, dropping the file
# headers and any pure-addition hunk. Used by the "orig" mode so operator-added
# blocks (e.g. extra location {} sections) don't flood the output; only drift in
# the repo-provided content is shown.
filtered_hunks() {
    awk '
        /^--- / || /^\+\+\+ / { next }
        /^@@/ { if (keep) printf "%s", buf; buf = $0 "\n"; keep = 0; next }
        { buf = buf $0 "\n"; if (substr($0, 1, 1) == "-") keep = 1 }
        END { if (keep) printf "%s", buf }
    ' "$1"
}

subst_domain() { sed "s|__DOMAIN__|$DOMAIN|g" "$1"; }

# nftables template substitutes the runtime UIDs of the proxy users; replay
# that so a raw diff isn't dominated by UID lines.
render_nft() {
    uid443=$(id -u proxy443 2>/dev/null || echo __UID_PROXY443__)
    uid80=$(id -u proxy80  2>/dev/null || echo __UID_PROXY80__)
    uid_postfix=$(id -u postfix 2>/dev/null || echo __UID_POSTFIX__)
    sed -e "s|__UID_PROXY443__|$uid443|g" \
        -e "s|__UID_PROXY80__|$uid80|g" \
        -e "s|__UID_POSTFIX__|$uid_postfix|g" "$1"
}

check_pair() {
    src=$1; dst=$2; render=${3:-cat}
    if [ ! -e "$src" ]; then
        echo "SKIP     $dst  (repo source $src missing)"
        return
    fi
    if [ ! -e "$dst" ]; then
        echo "MISSING  $dst  (source: $src)"
        status=1
        return
    fi
    exp="$tmp/exp.$$"
    # shellcheck disable=SC2086
    eval "$render \"\$src\"" > "$exp"
    if cmp -s "$exp" "$dst"; then
        echo "OK       $dst"
    else
        echo "DIFFER   $dst  (source: $src)"
        [ "$VERBOSE" = 1 ] && show_diff "$exp" "$dst"
        status=1
    fi
    rm -f "$exp"
}

# render_vhost SRC — replay vps-mcp-init.sh's server_name substitution for the
# container currently being checked ($sub is set by the caller from the
# container's /etc/vps-mcp-env).
render_vhost() { sed "s/server_name _;/server_name $sub;/g" "$1"; }

# norm_cert — canonicalise the ssl_certificate / ssl_certificate_key directive
# lines (read on stdin). vps-mcp-init.sh rewrites them to the Let's Encrypt live
# path on success, or leaves the image's self-signed default if certbot failed;
# both are legitimate, so the actual path must not read as drift.
norm_cert() {
    sed -E -e 's|^([[:space:]]*ssl_certificate_key)[[:space:]].*|\1 __KEY__;|' \
           -e 's|^([[:space:]]*ssl_certificate)[[:space:]].*|\1 __CERT__;|'
}

# check_in_container CONTAINER SRC DST [render] [normalize] [mode]
#   Compare a file inside a running container against the repo copy.
#     render     optional cmd (given the SRC path) that replays install-time
#                edits; defaults to plain `cat`.
#     normalize  optional filter (reads stdin) applied to BOTH the expected and
#                the actual content before comparison, to mask lines that
#                legitimately vary at runtime; defaults to `cat`.
#     mode       ""     (default) exact compare — ANY difference is drift; the
#                       diff body is shown only when VERBOSE=1.
#                "orig" repo-content-preserved compare, for the nginx configs an
#                       operator is expected to EXTEND. Lines added in the
#                       container are ignored; only removals/changes to the
#                       repo-provided content count as drift, and only those are
#                       shown (even in summary mode) so locally-added location
#                       blocks don't flood the output.
check_in_container() {
    c=$1; src=$2; dst=$3; render=${4:-cat}; normalize=${5:-cat}; mode=${6:-}
    if [ ! -e "$src" ]; then
        echo "SKIP     $c:$dst  (repo source $src missing)"
        return
    fi
    actual="$tmp/actual"
    if ! podman exec "$c" cat "$dst" > "$actual" 2>/dev/null; then
        echo "MISSING  $c:$dst  (source: $src)"
        status=1
        return
    fi
    exp="$tmp/exp"
    # shellcheck disable=SC2086
    eval "$render \"\$src\"" | $normalize > "$exp"
    # shellcheck disable=SC2086
    $normalize < "$actual" > "$actual.norm"

    if cmp -s "$exp" "$actual.norm"; then
        echo "OK       $c:$dst"
        return
    fi

    if [ "$mode" = orig ]; then
        diff -u "$exp" "$actual.norm" > "$tmp/raw.diff"
        removed=$(sed '1,2d' "$tmp/raw.diff" | grep -c '^-')
        added=$(sed '1,2d' "$tmp/raw.diff" | grep -c '^+')
        if [ "$removed" -eq 0 ]; then
            # Every repo line is still present; the only differences are lines
            # the operator added locally — a customisation, not drift.
            echo "OK       $c:$dst  (repo content preserved; +$added local line(s))"
            [ "$VERBOSE" = 1 ] && sed '1,2d' "$tmp/raw.diff" | sed 's/^/    /' | head -n 40
            return
        fi
        echo "DIFFER   $c:$dst  (source: $src; repo content changed)"
        if [ "$VERBOSE" = 1 ]; then
            sed '1,2d' "$tmp/raw.diff" | sed 's/^/    /' | head -n 40
        else
            filtered_hunks "$tmp/raw.diff" | sed 's/^/    /' | head -n 40
        fi
        status=1
        return
    fi

    echo "DIFFER   $c:$dst  (source: $src)"
    [ "$VERBOSE" = 1 ] && show_diff "$exp" "$actual.norm"
    status=1
}

# ── host-side files (skipped when checking a single container) ────────────────
if [ -z "$ONLY" ]; then

# ── proxy sockets/services (install-services) ────────────────────────────────
check_pair host/systemd/vps-proxy443.socket   /etc/systemd/system/vps-proxy443.socket
check_pair host/systemd/vps-proxy443.service  /etc/systemd/system/vps-proxy443.service
check_pair host/systemd/vps-proxy80.socket    /etc/systemd/system/vps-proxy80.socket
check_pair host/systemd/vps-proxy80.service   /etc/systemd/system/vps-proxy80.service

# ── weekly reboot units ──────────────────────────────────────────────────────
check_pair host/systemd/vps-mcp-reboot.service /etc/systemd/system/vps-mcp-reboot.service
check_pair host/systemd/vps-mcp-reboot.timer   /etc/systemd/system/vps-mcp-reboot.timer

# ── nftables ─────────────────────────────────────────────────────────────────
check_pair host/nftables/vps-mcp.nft.tmpl      /etc/nftables.d/vps-mcp.nft        render_nft

# ── opendkim ────────────────────────────────────────────────────────────────
check_pair host/opendkim/opendkim.conf.tmpl    /etc/opendkim.conf                 subst_domain

# ── BIND (paths differ between apt and dnf) ──────────────────────────────────
if command -v dnf >/dev/null 2>&1; then
    check_pair host/bind/named.conf.tmpl       /etc/named.conf
    _bind_local=/etc/named/named.conf.local
    _bind_zone_dir=/var/named
else
    _bind_local=/etc/bind/named.conf.local
    _bind_zone_dir=/etc/bind/zones
fi
_render_bind_local() {
    sed -e "s|__DOMAIN__|$DOMAIN|g" \
        -e "s|__BIND_ZONE_DIR__|$_bind_zone_dir|g" "$1"
}
check_pair host/bind/named.conf.local.tmpl     "$_bind_local"                     _render_bind_local

# ── dnf-automatic (dnf hosts only) ───────────────────────────────────────────
if command -v dnf >/dev/null 2>&1; then
    check_pair host/dnf/automatic.conf         /etc/dnf/automatic.conf
fi

# ── optional sshsec.done bits (only reported if installed) ───────────────────
if [ -e /etc/ssh/sshd_config.d/00-vps-mcp-hardening.conf ]; then
    check_pair host/ssh/00-vps-mcp-hardening.conf \
                                                /etc/ssh/sshd_config.d/00-vps-mcp-hardening.conf
fi
if [ -e /etc/fail2ban/jail.d/00-vps-mcp.conf ]; then
    check_pair host/fail2ban/jail.d/00-vps-mcp.conf \
                                                /etc/fail2ban/jail.d/00-vps-mcp.conf
fi

# ── container image staleness (informational) ────────────────────────────────
# The MCP app inside each container is refreshed in place by `make mcpupdate`,
# but the image itself only picks up repo changes when `make image` is re-run.
# Compare the repo's container/mcp/{index.mjs,package.json} against the copies
# baked into the image so image drift is visible too.
if command -v podman >/dev/null 2>&1 && podman image exists "${IMAGE:-vps-mcp:latest}" 2>/dev/null; then
    for f in container/mcp/index.mjs container/mcp/package.json; do
        base=$(basename "$f")
        baked="$tmp/baked.$base"
        if podman run --rm --entrypoint cat "${IMAGE:-vps-mcp:latest}" "/opt/mcp/$base" > "$baked" 2>/dev/null; then
            if cmp -s "$f" "$baked"; then
                echo "OK       image:${IMAGE:-vps-mcp:latest}:/opt/mcp/$base"
            else
                echo "DIFFER   image:${IMAGE:-vps-mcp:latest}:/opt/mcp/$base  (source: $f) — run 'make image' to rebuild"
                status=1
            fi
        fi
    done
fi

fi  # end host-side (ONLY unset)

# ── in-container files + nginx syntax (per running container) ─────────────────
# `make mcpupdate` only replaces /opt/mcp/{index.mjs,package.json} inside each
# container; the nginx config, systemd unit and init/deploy scripts keep
# whatever the image shipped when the container was created. A container built
# from an old image therefore runs stale files that no host-side check reveals.
# For every running <name>-web container we diff those baked files against the
# repo and, crucially, run `nginx -t` inside the container — the direct guard
# against a container whose nginx cannot load its config (e.g. a duplicate
# directive that keeps nginx down while the rest of the container looks healthy).
# The two nginx configs pass always_diff=1 so their drift is shown even in the
# summary `make check`; everything else honours VERBOSE.
if command -v podman >/dev/null 2>&1; then
    if [ -n "$ONLY" ]; then
        if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$ONLY"; then
            containers=$ONLY
        else
            echo "Error: container $ONLY is not running (or does not exist)." >&2
            exit 1
        fi
    else
        containers=$(podman ps --filter name=-web --format '{{.Names}}' 2>/dev/null)
    fi
    for c in $containers; do
        echo "---- container: $c ----"
        # SUBDOMAIN drives the server_name substitution vps-mcp-init.sh applied.
        sub=$(podman exec "$c" sed -n 's/^SUBDOMAIN=//p' /etc/vps-mcp-env 2>/dev/null)
        [ -n "$sub" ] || echo "NOTE     $c: SUBDOMAIN unknown (/etc/vps-mcp-env unreadable); server_name diff may be noisy"

        check_in_container "$c" container/mcp/index.mjs             /opt/mcp/index.mjs
        check_in_container "$c" container/mcp/package.json          /opt/mcp/package.json
        check_in_container "$c" container/systemd/mcp-server.service /etc/systemd/system/mcp-server.service
        check_in_container "$c" container/systemd/vps-mcp-init.sh   /usr/local/bin/vps-mcp-init.sh
        check_in_container "$c" container/systemd/certbot-deploy.sh /usr/local/bin/certbot-deploy.sh
        # nginx configs use "orig" mode: operators are expected to add their own
        # location blocks, so only drift in the repo-provided content is flagged.
        check_in_container "$c" container/nginx/nginx.conf          /etc/nginx/nginx.conf          cat cat orig
        # vps-mcp.conf: replay the server_name substitution and normalise the
        # ssl_certificate* lines on both sides (see render_vhost / norm_cert).
        check_in_container "$c" container/nginx/vps-mcp.conf        /etc/nginx/conf.d/vps-mcp.conf render_vhost norm_cert orig

        if podman exec "$c" nginx -t >"$tmp/nginx-t" 2>&1; then
            echo "OK       $c: nginx -t (configuration valid)"
        else
            echo "FAIL     $c: nginx -t (configuration invalid)"
            sed 's/^/    /' "$tmp/nginx-t"
            status=1
        fi
    done
elif [ -n "$ONLY" ]; then
    echo "Error: podman not available." >&2
    exit 1
fi

exit $status
