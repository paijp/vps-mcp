# https://github.com/paijp/vps-subdomain-mcp

IMAGE ?= vps-mcp:latest

# After %.setupdone runs, IP (and the BIND paths) are stored in
# /etc/vps-mcp/host.env; OAUTH_HOST is added by the oauth container target.
IP         ?= $(shell grep '^IP='         /etc/vps-mcp/host.env 2>/dev/null | cut -d= -f2)
OAUTH_HOST ?= $(shell grep '^OAUTH_HOST=' /etc/vps-mcp/host.env 2>/dev/null | cut -d= -f2)

# Parse "fqdn__email" stems
fqdn_of  = $(word 1,$(subst __, ,$(1)))
email_of = $(word 2,$(subst __, ,$(1)))

.DEFAULT_GOAL := help
.PHONY: help image install-binaries install-services list domains mcpupdate check checkall

# ── help ──────────────────────────────────────────────────────────────────────

help:
	@printf "vps-mcp multidomain — several domains on one host, one container per hostname\n\n"
	@printf "Host setup (run once as root):\n"
	@printf "  make 203.0.113.1.setupdone\n"
	@printf "      Packages, BIND, DKIM relay, vpsmcp-net, proxy sockets, nftables.\n"
	@printf "      Registers no domain; IP is stored in /etc/vps-mcp/host.env.\n\n"
	@printf "Optional hardening:\n"
	@printf "  make sshsec.done          Disable SSH password auth + install fail2ban\n\n"
	@printf "Domains (DNS zones):\n"
	@printf "  cp example.com.dns ksy.jp.dns; vi ksy.jp.dns\n"
	@printf "  make ksy.jp.dnsdone       Register or update the zone from ksy.jp.dns\n"
	@printf "                            (re-runs only when ksy.jp.dns changed)\n"
	@printf "  make ksy.jp.undns         Remove the zone (no container may use it)\n"
	@printf "  make domains              List registered domains and zone serials\n\n"
	@printf "Rebuild components individually:\n"
	@printf "  make image                Build container image\n"
	@printf "  make install-binaries     Build and install Go proxy binaries\n"
	@printf "  make install-services     (Re)install socket units and nftables\n\n"
	@printf "Container management (container name = <hostname>-web):\n"
	@printf "  make oauth.ksy.jp__admin@ex.com.done   GitHub-login broker, one per host\n"
	@printf "                                         (needs /etc/vps-mcp/oauth.env)\n"
	@printf "  make test.ksy.jp__alice@ex.com.done    VPS for alice at test.ksy.jp\n"
	@printf "  make pa-i.jp__bob@ex.com.done          VPS for bob at the domain apex\n"
	@printf "  make list                              List VPS containers by domain\n\n"
	@printf "Update the MCP app (index.mjs / package.json):\n"
	@printf "  make image                Rebuild the image (affects ONLY containers created later)\n"
	@printf "  make mcpupdate            Update ALL running containers in place (stop + cp + npm install + start,\n"
	@printf "                            plus any missing diagnostic tools: ss, ps, lsof, sqlite3, jq)\n"
	@printf "  make test.ksy.jp.mcpupdate  Update a single running container (stem -> <stem>-web)\n"
	@printf "      Run BOTH 'make image' and 'make mcpupdate' to cover future and existing containers.\n\n"
	@printf "Check installed files against this checkout:\n"
	@printf "  make check\n"
	@printf "      Summary: one status line (OK/DIFFER/MISSING) per file for the\n"
	@printf "      installed proxy units, nftables, BIND/opendkim/dnf-automatic\n"
	@printf "      configs, every registered zone (named-checkzone), the container\n"
	@printf "      image's MCP app, and the files baked into every running\n"
	@printf "      <name>-web container. Also runs 'nginx -t' inside each container,\n"
	@printf "      and reports any missing diagnostic tool (ss/ps/lsof/sqlite3/jq).\n"
	@printf "  make checkall\n"
	@printf "      Same checks, but print the full diff for EVERY differing file.\n"
	@printf "  make test.ksy.jp.check\n"
	@printf "      Verbose check of a single container (stem -> <stem>-web);\n"
	@printf "      skips the host-side checks.\n\n"
	@printf "Variables:\n"
	@printf "  IMAGE   Container image tag (default: vps-mcp:latest)\n"
	@printf "  NS1     Primary NS hostname written into every zone (default ns1.<domain>;\n"
	@printf "          set NS1=ns1.ksy.jp in host.env to share one glue record)\n"

# ── host setup ────────────────────────────────────────────────────────────────
# Usage: make 203.0.113.1.setupdone
#
# 1. Write /etc/vps-mcp/host.env  (IP, BIND_ZONE_DIR, BIND_CONF)
# 2. Install BIND9 (authoritative only, no zones yet — see %.dnsdone)
# 3. Install opendkim (per-domain KeyTable/SigningTable) and the relay postfix
# 4. Create vpsmcp-net Podman network (10.89.0.0/24, DNS disabled)
# 5. Build container image
# 6. Install Go proxy binaries
# 7. Install proxy socket units + nftables (with proxy user UID substitution)

%.setupdone:
	$(eval _IP := $*)
	@echo "$(_IP)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$$' || \
	    { echo "Error: format is  IP.setupdone  e.g. 203.0.113.1.setupdone"; exit 1; }
	mkdir -p /etc/vps-mcp
	touch /etc/vps-mcp/host.env
	sed -i '/^IP=/d' /etc/vps-mcp/host.env
	echo "IP=$(_IP)" >> /etc/vps-mcp/host.env
	if [ ! -e /etc/vps-mcp/oauth.env ]; then \
	    printf 'GITHUB_CLIENT_ID=...\nGITHUB_CLIENT_SECRET=...\n' > /etc/vps-mcp/oauth.env; \
	    chmod 600 /etc/vps-mcp/oauth.env; \
	    echo "Created /etc/vps-mcp/oauth.env template — fill in GitHub OAuth App credentials before 'make oauth.<domain>__<email>.done'."; \
	fi
	if [ ! -e /swapfile ]; then \
	    fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024; \
	    chmod 600 /swapfile; \
	    mkswap /swapfile; \
	    swapon /swapfile; \
	    grep -qF '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab; \
	fi
	if command -v apt-get >/dev/null 2>&1; then \
	    apt-get update; \
	    apt-get upgrade -y; \
	    apt-get install -y bind9 podman golang-go postfix opendkim opendkim-tools unattended-upgrades; \
	    BIND_ZONE_DIR=/etc/bind/zones; \
	    BIND_CONF=/etc/bind/named.conf.local; \
	elif command -v dnf >/dev/null 2>&1; then \
	    dnf install -y epel-release || dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$$(rpm -E %rhel).noarch.rpm"; \
	    dnf upgrade -y; \
	    dnf install -y bind bind-utils podman golang postfix opendkim opendkim-tools dnf-automatic; \
	    BIND_ZONE_DIR=/var/named; \
	    mkdir -p /etc/named; \
	    BIND_CONF=/etc/named/named.conf.local; \
	    install -m 644 host/bind/named.conf.tmpl /etc/named.conf; \
	else echo "Error: no supported package manager (apt-get or dnf)"; exit 1; fi; \
	mkdir -p $$BIND_ZONE_DIR $$(dirname $$BIND_CONF)/zones.d; \
	sed -i -e '/^BIND_ZONE_DIR=/d' -e '/^BIND_CONF=/d' /etc/vps-mcp/host.env; \
	printf 'BIND_ZONE_DIR=%s\nBIND_CONF=%s\n' "$$BIND_ZONE_DIR" "$$BIND_CONF" >> /etc/vps-mcp/host.env; \
	test -f $$BIND_CONF || echo "// No zones yet — make <domain>.dnsdone adds them." > $$BIND_CONF
	touch /etc/vps-mcp/domains
	systemctl enable --now named
	mkdir -p /etc/opendkim/keys; \
	touch /etc/opendkim/KeyTable /etc/opendkim/SigningTable; \
	chgrp opendkim /etc/opendkim/KeyTable /etc/opendkim/SigningTable; \
	chmod 640 /etc/opendkim/KeyTable /etc/opendkim/SigningTable; \
	install -m 644 host/opendkim/opendkim.conf.tmpl /etc/opendkim.conf; \
	systemctl enable --now opendkim; \
	postconf -e "inet_interfaces = all"; \
	postconf -e "inet_protocols = ipv4"; \
	postconf -e "mynetworks = 127.0.0.0/8 10.89.0.0/24"; \
	postconf -e "smtpd_relay_restrictions = permit_mynetworks reject_unauth_destination"; \
	postconf -e "smtpd_milters = inet:127.0.0.1:8891"; \
	postconf -e "non_smtpd_milters = inet:127.0.0.1:8891"; \
	postconf -e "milter_protocol = 6"; \
	postconf -e "milter_default_action = accept"; \
	systemctl enable --now postfix
	podman network create --subnet 10.89.0.0/24 --disable-dns vpsmcp-net 2>/dev/null || true
	systemctl enable --now podman.socket
	systemctl enable podman-restart.service
	if command -v apt-get >/dev/null 2>&1; then \
	    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
	        > /etc/apt/apt.conf.d/20auto-upgrades; \
	    systemctl enable --now unattended-upgrades; \
	elif command -v dnf >/dev/null 2>&1; then \
	    install -m 644 host/dnf/automatic.conf /etc/dnf/automatic.conf; \
	    systemctl enable --now dnf-automatic.timer; \
	    systemctl disable --now dnf-makecache.timer 2>/dev/null || true; \
	fi
	# Persistent journal: without /var/log/journal the host journal lives in
	# tmpfs and is lost on reboot, making incidents (OOM, swap thrash)
	# undiagnosable after the fact.
	mkdir -p /var/log/journal
	systemctl restart systemd-journald
	# zram swap: dnf runs in every container are memory-hungry; on a small host
	# they can push the machine into disk-swap thrash (CPU + I/O pinned, SSH
	# dead). Compressed in-RAM swap absorbs those spikes far more gracefully.
	if command -v apt-get >/dev/null 2>&1; then \
	    apt-get install -y systemd-zram-generator || true; \
	elif command -v dnf >/dev/null 2>&1; then \
	    dnf install -y zram-generator || true; \
	fi
	printf '[zram0]\nzram-size = ram / 2\n' > /etc/systemd/zram-generator.conf
	systemctl daemon-reload
	systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
	install -m 644 host/systemd/vps-mcp-reboot.service /etc/systemd/system/
	install -m 644 host/systemd/vps-mcp-reboot.timer   /etc/systemd/system/
	systemctl daemon-reload
	systemctl enable --now vps-mcp-reboot.timer
	$(MAKE) image
	$(MAKE) install-binaries
	$(MAKE) install-services IP=$(_IP)
	@touch $@

# ── image ─────────────────────────────────────────────────────────────────────

image:
	podman build -t $(IMAGE) container/

# ── install-binaries ──────────────────────────────────────────────────────────

install-binaries:
	cd proxy && go build -o /usr/local/sbin/list-containers ./cmd/list-containers
	chown root:root /usr/local/sbin/list-containers
	chmod 0755      /usr/local/sbin/list-containers
	cd proxy && go build -o /usr/local/sbin/vps-proxy       ./cmd/vps-proxy
	cd proxy && go build -o /usr/local/sbin/vps-proxy-http  ./cmd/vps-proxy-http

# ── install-services ──────────────────────────────────────────────────────────

install-services:
	@test -n "$(IP)" || \
	    { echo "Error: IP is required.  Run make <IP>.setupdone first."; exit 1; }
	mkdir -p /etc/vps-mcp
	touch /etc/vps-mcp/host.env /etc/vps-mcp/domains
	useradd -r -s /sbin/nologin proxy443 2>/dev/null || true
	useradd -r -s /sbin/nologin proxy80  2>/dev/null || true
	install -m 644 host/systemd/vps-proxy443.socket  /etc/systemd/system/
	install -m 644 host/systemd/vps-proxy443.service /etc/systemd/system/
	install -m 644 host/systemd/vps-proxy80.socket   /etc/systemd/system/
	install -m 644 host/systemd/vps-proxy80.service  /etc/systemd/system/
	systemctl daemon-reload
	systemctl enable --now vps-proxy443.socket vps-proxy80.socket
	mkdir -p /etc/nftables.d; \
	UID443=$$(id -u proxy443); UID80=$$(id -u proxy80); UID_POSTFIX=$$(id -u postfix); \
	sed -e "s|__UID_PROXY443__|$$UID443|g" \
	    -e "s|__UID_PROXY80__|$$UID80|g" \
	    -e "s|__UID_POSTFIX__|$$UID_POSTFIX|g" \
	    host/nftables/vps-mcp.nft.tmpl > /etc/nftables.d/vps-mcp.nft
	grep -qF 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf 2>/dev/null || \
	    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
	systemctl enable nftables
	nft -f /etc/nftables.d/vps-mcp.nft
	# Outbound mail limits per container (client IP on the relay):
	#   - anvil: 5 messages / 20 recipients per minute (excess gets 4xx, so the
	#     container's Postfix queues and retries). Exceptions default to
	#     $$mynetworks, which includes the containers, so clear them.
	#   - vps-mcp-mailquota policy: 200 messages per day (excess gets 5xx).
	# Idempotent, so re-running install-services applies it to existing hosts.
	useradd -r -s /sbin/nologin vpsmailq 2>/dev/null || true
	install -m 755 host/postfix/vps-mcp-mailquota.sh /usr/local/libexec/vps-mcp-mailquota.sh
	install -d -m 700 -o vpsmailq -g vpsmailq /var/lib/vps-mcp-mailquota
	postconf -M "vps-mcp-mailquota/unix=vps-mcp-mailquota unix - n n - 0 spawn user=vpsmailq argv=/usr/local/libexec/vps-mcp-mailquota.sh"
	postconf -e "vps-mcp-mailquota_time_limit = 3600s"
	postconf -e "anvil_rate_time_unit = 60s"
	postconf -e "smtpd_client_message_rate_limit = 5"
	postconf -e "smtpd_client_recipient_rate_limit = 20"
	postconf -e "smtpd_client_event_limit_exceptions ="
	postconf -e "smtpd_end_of_data_restrictions = check_policy_service unix:private/vps-mcp-mailquota"
	systemctl reload postfix

# ── sshsec.done — optional SSH hardening ──────────────────────────────────────
# Usage: make sshsec.done
#
# Not called by setupdone — run it separately when you want to lock down SSH.
#   1. Disable password authentication (access is key-based).
#   2. Install + enable fail2ban with the nftables banaction.
#
# Explicit target, so it takes precedence over the %.done pattern rule below.
sshsec.done:
	# Harden SSH: disable password authentication (access is key-based).
	# A container compromise gives the participant root inside their container
	# and reachability to the host's :22, so password login must be off to
	# remove brute-force exposure. The drop-in's 00- prefix wins first-match;
	# validate with sshd -t before reloading so a bad config can't lock us out.
	mkdir -p /etc/ssh/sshd_config.d
	install -m 600 host/ssh/00-vps-mcp-hardening.conf /etc/ssh/sshd_config.d/00-vps-mcp-hardening.conf
	sshd -t && { systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true; }
	# Install fail2ban for SSH brute-force protection.
	# Uses the nftables banaction (firewalld is masked on this host).
	# The 00-vps-mcp.conf drop-in overrides the distro's 00-firewalld.conf.
	if command -v apt-get >/dev/null 2>&1; then \
	    apt-get install -y fail2ban; \
	elif command -v dnf >/dev/null 2>&1; then \
	    dnf install -y fail2ban; \
	fi
	mkdir -p /etc/fail2ban/jail.d
	install -m 644 host/fail2ban/jail.d/00-vps-mcp.conf /etc/fail2ban/jail.d/00-vps-mcp.conf
	systemctl enable --now fail2ban
	@touch $@

# ── DNS zones ─────────────────────────────────────────────────────────────────
# Usage: cp example.com.dns ksy.jp.dns; vi ksy.jp.dns; make ksy.jp.dnsdone
#
# <domain>.dns holds the operator-managed records (MX, TXT, CNAME, ...); the
# host-managed part (SOA, NS, @/*/ns1 A, SPF, DMARC, DKIM) comes from
# host/bind/zone.tmpl. The first run registers the zone (BIND zone statement,
# DKIM key, opendkim tables, /etc/vps-mcp/domains for the proxies); later runs
# update it with a bumped serial. A bad records file or a zone that fails
# named-checkzone leaves the live zone untouched. A copy of the records file
# is kept in /etc/vps-mcp/zones/ in case the checkout is lost.
#
# The "dnsdone"/"undns" suffixes have no dot before them on purpose, so they
# never overlap the %.done container rule.

%.dnsdone: %.dns
	sh scripts/zone.sh apply $* $<
	@touch $@

%.undns:
	sh scripts/zone.sh remove $*
	rm -f $*.dnsdone

domains:
	@test -s /etc/vps-mcp/domains || { echo "No domains registered."; exit 0; }; \
	. /etc/vps-mcp/host.env; \
	while read -r d; do \
	    serial=$$(awk '/SOA/ { s = 1 } s && $$1 ~ /^[0-9]+$$/ { print $$1; exit }' "$$BIND_ZONE_DIR/$$d.zone" 2>/dev/null); \
	    printf '%-30s serial %s\n' "$$d" "$${serial:-?}"; \
	done < /etc/vps-mcp/domains

# ── container creation ────────────────────────────────────────────────────────
# Usage: make test.ksy.jp__alice@gmail.com.done   (container test.ksy.jp-web)
#        make pa-i.jp__bob@gmail.com.done         (domain apex: pa-i.jp-web)
#        make oauth.ksy.jp__admin@gmail.com.done  (GitHub-login broker; needs
#                                                  /etc/vps-mcp/oauth.env)
# The hostname must be a registered domain (make <domain>.dnsdone) or one
# label below it. Unknown names under a domain are served by its apex
# container, if any.
#
# GitHub OAuth login: create one oauth.<domain> container per host, before the
# others. It is the single registered GitHub redirect target
# (https://oauth.<domain>/mcp/callback) for every domain on this host and the
# only container that holds the GitHub OAuth App credentials. Put them in
# /etc/vps-mcp/oauth.env (mode 600) first:
#     GITHUB_CLIENT_ID=...
#     GITHUB_CLIENT_SECRET=...
# Its hostname is saved as OAUTH_HOST in host.env. Every other container only
# learns OAUTH_BASE (https://$(OAUTH_HOST)) and grants a Bearer when the GitHub
# login's verified primary email matches NOTIFY_EMAIL.

%.done:
	$(eval _FQDN  := $(shell echo '$(call fqdn_of,$*)' | tr A-Z a-z))
	$(eval _EMAIL := $(call email_of,$*))
	$(eval _OAUTH := $(filter oauth.%,$(_FQDN)))
	@test -n "$(_EMAIL)" || \
	    { echo "Error: format is  <hostname>__<email>.done  e.g. test.ksy.jp__alice@gmail.com.done"; exit 1; }
	@test -n "$(IP)" || \
	    { echo "Error: IP not set.  Run make <IP>.setupdone first."; exit 1; }
	@d=$$(awk -v h="$(_FQDN)" '(h == $$0 || substr(h, length(h) - length($$0)) == "." $$0) && length($$0) > length(best) { best = $$0 } END { print best }' /etc/vps-mcp/domains 2>/dev/null); \
	test -n "$$d" || { echo "Error: $(_FQDN) is in no registered domain.  Run make <domain>.dnsdone first."; exit 1; }; \
	h="$(_FQDN)"; sub=$${h%"$$d"}; sub=$${sub%.}; \
	case "$$sub" in *.*) echo "Error: $(_FQDN) is more than one label below $$d."; exit 1;; esac
	@test -z "$(_OAUTH)" || test -f /etc/vps-mcp/oauth.env || \
	    { echo "Error: create /etc/vps-mcp/oauth.env (mode 600) with GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET before making the oauth container."; exit 1; }
	@test -z "$(_OAUTH)" || test -z "$(OAUTH_HOST)" || test "$(OAUTH_HOST)" = "$(_FQDN)" || \
	    { echo "Error: this host already has a GitHub-login broker ($(OAUTH_HOST)); only one is allowed."; exit 1; }
	@test -n "$(_OAUTH)" || test -n "$(OAUTH_HOST)" || \
	    { echo "Error: no GitHub-login broker yet.  Create it first: make oauth.<domain>__<email>.done"; exit 1; }
	$(if $(_OAUTH),sed -i '/^OAUTH_HOST=/d' /etc/vps-mcp/host.env && echo "OAUTH_HOST=$(_FQDN)" >> /etc/vps-mcp/host.env)
	podman run -d \
	    --name     $(_FQDN)-web \
	    --hostname $(_FQDN) \
	    --network  vpsmcp-net \
	    --systemd  always \
	    --restart  always \
	    --memory   1g \
	    --pids-limit 200 \
	    --cap-drop NET_RAW,NET_ADMIN \
	    --env      SUBDOMAIN=$(_FQDN) \
	    --env      MAIL_DOMAIN=$(_FQDN) \
	    --env      NOTIFY_EMAIL=$(_EMAIL) \
	    --env      OAUTH_BASE=https://$(if $(_OAUTH),$(_FQDN),$(OAUTH_HOST)) \
	    $(if $(_OAUTH),--env-file /etc/vps-mcp/oauth.env,) \
	    $(IMAGE)
	@echo "Letting the proxy refresh its routing table for the new container..."
	@sleep 10
	@echo "Waiting for the proxy to route the HTTP-01 path to $(_FQDN)..."
	@for i in $$(seq 60); do \
	    code=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
	        --resolve $(_FQDN):80:$(IP) \
	        http://$(_FQDN)/.well-known/acme-challenge/ping 2>/dev/null || true); \
	    if [ "$$code" = "404" ] || [ "$$code" = "200" ]; then \
	        echo "proxy ready (HTTP $$code) after $$i attempt(s)"; break; \
	    fi; \
	    sleep 2; \
	done
	podman exec $(_FQDN)-web /usr/local/bin/vps-mcp-init.sh
	@touch $@

# ── list ──────────────────────────────────────────────────────────────────────

list:
	@podman ps -a --filter "name=-web" --format "{{.Names}}\t{{.Status}}\t{{.IPAddress}}" | \
	awk -F'\t' 'NR == FNR { dom[NR] = $$0; nd = NR; next } \
	    { h = $$1; sub(/-web$$/, "", h); best = "(unregistered)"; \
	      for (i = 1; i <= nd; i++) { d = dom[i]; \
	          if ((h == d || substr(h, length(h) - length(d)) == "." d) && length(d) > length(b2)) { best = d; b2 = d } } \
	      b2 = ""; print best "\t" $$0 }' /etc/vps-mcp/domains - | sort | \
	awk -F'\t' '$$1 != prev { print "\n" $$1; prev = $$1 } { printf "  %-40s %-28s %s\n", $$2, $$3, $$4 }'

# ── MCP app update ─────────────────────────────────────────────────────────────
# The MCP app (index.mjs + its node_modules) is baked into the image and copied
# into each container's writable layer at build time. Updating therefore has two
# independent scopes, and a full rollout needs BOTH:
#
#   make image          rebuilds the image  → ONLY containers created afterwards.
#   make mcpupdate       patches every already-running container IN PLACE.
#   make <sub>.mcpupdate patches one running container (e.g. make test.ksy.jp.mcpupdate).
#
# In-place is used (not recreate) because each container holds persistent state
# in its writable layer — the Bearer token hash (/etc/mcp-server), the deploy
# owner binding, certbot certificates, and /var/www/html — which a recreate from
# a new image would discard. package.json is copied too and `npm install` is run
# so newly added dependencies (e.g. jose for OIDC) are present before restart.
#
# When upgrading the broker and content containers together, update the oauth
# container first (make oauth.<domain>.mcpupdate) so /mcp/resolve returns owner_id before
# the others try to bind it.

mcpupdate:
	@set -e; \
	cs="$$(podman ps --filter name=-web --format '{{.Names}}')"; \
	test -n "$$cs" || { echo "No running -web containers found."; exit 0; }; \
	for c in $$cs; do \
	    $(MAKE) --no-print-directory $${c%-web}.mcpupdate; \
	done

# ── check installed files vs this checkout ───────────────────────────────────
# Reports OK / DIFFER / MISSING for every host-side file the Makefile installs,
# plus the image-baked MCP app if podman + the image are present. Replays
# template substitutions (DOMAIN, BIND paths, proxy UIDs) so the comparison is
# meaningful. Especially useful for configs no update target refreshes — proxy
# units, nftables, opendkim, BIND — so a `git pull` doesn't silently leave the
# live host on an old copy. Then, for every running <name>-web container, diffs
# the baked nginx/systemd/init files (which `mcpupdate` never refreshes) and
# runs `nginx -t` inside the container to catch a config it cannot load.
#
#   check              summary (status line per file; nginx diffs still shown)
#   checkall           verbose (full diff for every differing file)
#   <stem>.check       verbose check of one container (<stem>-web), host skipped
check:
	@sh scripts/check-installed.sh

checkall:
	@VERBOSE=1 sh scripts/check-installed.sh

# Verbose check of a single running container. Stem is the hostname:
#   make test.ksy.jp.check   → test.ksy.jp-web
%.check:
	@VERBOSE=1 sh scripts/check-installed.sh $*-web

# Update one running container in place. Stem is the hostname:
#   make test.ksy.jp.mcpupdate   → test.ksy.jp-web
#   make oauth.ksy.jp.mcpupdate  → oauth.ksy.jp-web
%.mcpupdate:
	@set -e; \
	c="$*-web"; \
	podman container exists $$c || { echo "Error: container $$c not found."; exit 1; }; \
	echo "==> updating $$c"; \
	podman exec $$c systemctl stop mcp-server; \
	podman cp container/mcp/package.json $$c:/opt/mcp/package.json; \
	podman cp container/mcp/index.mjs    $$c:/opt/mcp/index.mjs; \
	podman exec $$c sh -c 'cd /opt/mcp && npm install --omit=dev'; \
	: '`npm install` leaves an already-present package that still satisfies its'; \
	: 'semver range untouched, so a container created months ago keeps its old'; \
	: '(vulnerable) express tree. `npm update` moves every dependency to the'; \
	: 'newest release inside its range. Non-fatal: a registry hiccup must not'; \
	: 'leave mcp-server stopped.'; \
	podman exec $$c sh -c 'cd /opt/mcp && npm update --omit=dev' || \
	    echo "    $$c: WARNING: npm update failed; dependencies not refreshed"; \
	podman exec $$c systemctl start mcp-server; \
	sh scripts/ensure-tools.sh $$c; \
	echo "    $$c updated"
