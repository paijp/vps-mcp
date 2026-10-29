# https://github.com/paijp/vps-subdomain-mcp

IMAGE ?= vps-mcp:latest

# After %.setupdone runs, IP (and the BIND paths) are stored in
# /etc/vps-mcp/host.env; OAUTH_HOST is added by the oauth container target.
IP         ?= $(shell grep '^IP='         /etc/vps-mcp/host.env 2>/dev/null | cut -d= -f2)
OAUTH_HOST ?= $(shell grep '^OAUTH_HOST=' /etc/vps-mcp/host.env 2>/dev/null | cut -d= -f2)

# Parse "[IP__]fqdn__email" stems. The optional leading IP is the old server a
# site moves from: the container starts in forward mode (port 443 passed
# through to it, see container/systemd/vps-mcp-mode.sh).
_words   = $(subst __, ,$(1))
_three   = $(word 3,$(call _words,$(1)))
fwd_of   = $(if $(call _three,$(1)),$(word 1,$(call _words,$(1))))
fqdn_of  = $(if $(call _three,$(1)),$(word 2,$(call _words,$(1))),$(word 1,$(call _words,$(1))))
email_of = $(if $(word 2,$(call _words,$(1))),$(lastword $(call _words,$(1))))

# check_fwd IP — empty, or a dotted IPv4 address.
define check_fwd
	@test -z "$(1)" || echo "$(1)" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$$' || \
	    { echo "Error: '$(1)' is not an IPv4 address (format: IP__hostname__email)."; exit 1; }
endef

# A literal comma, for $(call ...) arguments that contain one.
, := ,

# names3 FQDN — set _P, _S, _D to the production / staging / dev hostnames of
# the create3 set whose production hostname is FQDN (see scripts/names3.sh).
names3 = $(eval _N := $(shell sh scripts/names3.sh '$(1)'))$(eval _P := $(word 1,$(_N)))$(eval _S := $(word 2,$(_N)))$(eval _D := $(word 3,$(_N)))

.DEFAULT_GOAL := help
.PHONY: help image install-binaries install-services list domains mcpupdate check checkall

# ── help ──────────────────────────────────────────────────────────────────────

help:
	@printf "vps-mcp multidomain — several domains on one host, one container per hostname\n\n"
	@printf "Host setup (run once as root):\n"
	@printf "  make 203.0.113.1.setupdone\n"
	@printf "      Packages, BIND, DKIM relay, vpsmcp-net, proxy sockets, nftables.\n"
	@printf "      Registers no domain; IP is stored in /etc/vps-mcp/host.env.\n\n"
	@printf "  make 203.0.113.1.dnssetupdone\n"
	@printf "      BIND only (part of setupdone). Run alone to host DNS zones first\n"
	@printf "      while the existing web server keeps running.\n\n"
	@printf "Optional hardening:\n"
	@printf "  make sshsec.done          Disable SSH password auth + install fail2ban\n\n"
	@printf "Domains (DNS zones):\n"
	@printf "  cp example.com.dns example.org.dns; vi example.org.dns\n"
	@printf "  make example.org.dnsdone        Register or update the zone from example.org.dns\n"
	@printf "                                  (re-runs only when example.org.dns changed)\n"
	@printf "  make example.org.undns          Remove the zone (no container may use it)\n"
	@printf "  make domains                    List registered domains and zone serials\n\n"
	@printf "Rebuild components individually:\n"
	@printf "  make image                      Build container image\n"
	@printf "  make install-binaries           Build and install Go proxy binaries\n"
	@printf "  make install-services           (Re)install socket units and nftables\n\n"
	@printf "Container management (container name = <hostname>-web):\n"
	@printf "  make oauth.example.org__admin@example.com.done\n"
	@printf "                                  GitHub-login broker, one per host\n"
	@printf "                                  (needs /etc/vps-mcp/oauth.env)\n"
	@printf "  make test.example.org__alice@example.com.done\n"
	@printf "                                  VPS for alice at test.example.org\n"
	@printf "  make example.net__bob@example.com.done\n"
	@printf "                                  VPS for bob at the domain apex\n"
	@printf "  make list                       List VPS containers by domain\n\n"
	@printf "Three-container sets (production / staging / development):\n"
	@printf "  make shop.example.org__alice@example.com.create3\n"
	@printf "                                  shop.example.org (prod), shop-stg.example.org,\n"
	@printf "                                  shop-dev.example.org (the only one with MCP)\n"
	@printf "  make shop.example.org.dev2stg   Send dev's committed HEAD to staging, make install\n"
	@printf "  make shop.example.org.stg2prod  Show commits/stat (DIFF=1: full diff), ask,\n"
	@printf "                                  send staging's HEAD to production\n"
	@printf "  make shop.example.org.list3     Status and git HEAD of the three containers\n"
	@printf "      For a domain apex (example.org) the others are stg.example.org and dev.example.org.\n\n"
	@printf "Moving a site from an old server without downtime (forward mode):\n"
	@printf "  make 203.0.113.5__example.net__alice@example.com.done\n"
	@printf "                                  (or .create3) start in forward mode:\n"
	@printf "                                  443 passes through to 203.0.113.5, 80 proxies to it\n"
	@printf "  make example.net.getcert        Let's Encrypt cert (+ names in /etc/vps-mcp/cert-names)\n"
	@printf "                                  once DNS points here; re-run to retry or add names\n"
	@printf "  make example.net.unforward      Serve 443 here; app.d/forward.conf still proxies the rest\n"
	@printf "  make example.net.forward        Back to forward mode (OLD=<IP> to change the target)\n"
	@printf "  make example.net.mode           Show mode and certificate\n\n"
	@printf "Update the MCP app (index.mjs / package.json):\n"
	@printf "  make image                Rebuild the image (affects ONLY containers created later)\n"
	@printf "  make mcpupdate            Update ALL running MCP containers in place (stop + cp + npm install + start,\n"
	@printf "                            plus any missing diagnostic tools: ss, ps, lsof, sqlite3, jq, dig),\n"
	@printf "                            and the helper scripts (vps-mcp-mode.sh, ...) in EVERY container\n"
	@printf "  make test.example.org.mcpupdate  Update a single running container (stem -> <stem>-web;\n"
	@printf "                            for a create3 set its dev container, plus the scripts of all three)\n"
	@printf "  make test.example.org.scriptupdate  Only the helper scripts and tools of one container\n"
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
	@printf "  make test.example.org.check\n"
	@printf "      Verbose check of a single container (stem -> <stem>-web);\n"
	@printf "      skips the host-side checks.\n\n"
	@printf "Variables:\n"
	@printf "  IMAGE   Container image tag (default: vps-mcp:latest)\n"
	@printf "  NS1     Primary NS hostname written into every zone (default ns1.<domain>;\n"
	@printf "          set NS1=ns1.example.org in host.env to share one glue record)\n"

# ── host setup ────────────────────────────────────────────────────────────────
# Usage: make 203.0.113.1.setupdone
#        make 203.0.113.1.dnssetupdone   (BIND only — run alone to move a
#            domain's DNS here first while the web server stays as it is;
#            setupdone runs it and keeps its zones)
#
# 1. Write /etc/vps-mcp/host.env  (IP, BIND_ZONE_DIR, BIND_CONF)
# 2. Install BIND9 (authoritative only, no zones yet — see %.dnsdone)
# 3. Install opendkim (per-domain KeyTable/SigningTable) and the relay postfix
# 4. Create vpsmcp-net Podman network (10.89.0.0/24, DNS disabled)
# 5. Build container image
# 6. Install Go proxy binaries
# 7. Install proxy socket units + nftables (with proxy user UID substitution)

%.dnssetupdone:
	$(eval _IP := $*)
	@echo "$(_IP)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$$' || \
	    { echo "Error: format is  IP.dnssetupdone  e.g. 203.0.113.1.dnssetupdone"; exit 1; }
	mkdir -p /etc/vps-mcp
	touch /etc/vps-mcp/host.env /etc/vps-mcp/domains
	sed -i '/^IP=/d' /etc/vps-mcp/host.env
	echo "IP=$(_IP)" >> /etc/vps-mcp/host.env
	if command -v apt-get >/dev/null 2>&1; then \
	    apt-get install -y bind9 opendkim-tools; \
	    BIND_ZONE_DIR=/etc/bind/zones; \
	    BIND_CONF=/etc/bind/named.conf.local; \
	elif command -v dnf >/dev/null 2>&1; then \
	    dnf install -y epel-release || dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$$(rpm -E %rhel).noarch.rpm"; \
	    dnf install -y bind bind-utils opendkim opendkim-tools; \
	    BIND_ZONE_DIR=/var/named; \
	    mkdir -p /etc/named; \
	    BIND_CONF=/etc/named/named.conf.local; \
	    install -m 644 host/bind/named.conf.tmpl /etc/named.conf; \
	else echo "Error: no supported package manager (apt-get or dnf)"; exit 1; fi; \
	mkdir -p $$BIND_ZONE_DIR $$(dirname $$BIND_CONF)/zones.d; \
	sed -i -e '/^BIND_ZONE_DIR=/d' -e '/^BIND_CONF=/d' /etc/vps-mcp/host.env; \
	printf 'BIND_ZONE_DIR=%s\nBIND_CONF=%s\n' "$$BIND_ZONE_DIR" "$$BIND_CONF" >> /etc/vps-mcp/host.env; \
	test -f $$BIND_CONF || echo "// No zones yet — make <domain>.dnsdone adds them." > $$BIND_CONF
	systemctl enable --now named
	@echo "BIND is up. If firewalld is still running, open DNS:"
	@echo "    firewall-cmd --permanent --add-service=dns && firewall-cmd --reload"
	@touch $@

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
	    apt-get install -y podman golang-go postfix opendkim opendkim-tools unattended-upgrades; \
	elif command -v dnf >/dev/null 2>&1; then \
	    dnf install -y epel-release || dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$$(rpm -E %rhel).noarch.rpm"; \
	    dnf upgrade -y; \
	    dnf install -y podman golang postfix opendkim opendkim-tools dnf-automatic; \
	else echo "Error: no supported package manager (apt-get or dnf)"; exit 1; fi
	$(MAKE) $(_IP).dnssetupdone
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
	# firewalld (enabled by default on Rocky) keeps its own nftables table, which
	# can drop traffic vps-mcp.nft allows and rebuilds rules on start/reload,
	# wiping the vps-mcp and podman rules. vps-mcp.nft is the only firewall here.
	systemctl disable --now firewalld 2>/dev/null || true
	systemctl mask firewalld
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
	# A running proxy keeps the old binary until restarted; the socket units
	# hold the listening sockets, so new connections wait instead of failing.
	systemctl try-restart vps-proxy443.service vps-proxy80.service

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
	UID_NAMED=$$(id -u named 2>/dev/null || id -u bind 2>/dev/null || echo 0); \
	sed -e "s|__UID_PROXY443__|$$UID443|g" \
	    -e "s|__UID_PROXY80__|$$UID80|g" \
	    -e "s|__UID_POSTFIX__|$$UID_POSTFIX|g" \
	    -e "s|__UID_NAMED__|$$UID_NAMED|g" \
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
	# Three-container sets (create3). Harmless on a host without any:
	#   - vps-mcp-containers: name/IP list for the mail policy (staging lookup)
	#   - staging mail copies: the policy BCCs stgcapture+<staging>@localhost;
	#     the alias drops them in a Maildir, vps-mcp-stgmail.path hands them to
	#     the dev container (recipient_delimiter makes the +<staging> part work)
	#   - staging view: an OCI hook binds each staging rootfs read-only under
	#     /run/vps-mcp/view, set up at boot by vps-mcp-view.service
	command -v jq >/dev/null 2>&1 || dnf install -y jq
	install -m 755 host/three/vps-mcp-containers.sh      /usr/local/libexec/vps-mcp-containers.sh
	install -m 755 host/three/vps-mcp-stgmail-forward.sh /usr/local/libexec/vps-mcp-stgmail-forward.sh
	install -m 755 host/three/vps-mcp-stgview-hook.sh    /usr/local/libexec/vps-mcp-stgview-hook.sh
	install -m 755 host/three/vps-mcp-view-setup.sh      /usr/local/libexec/vps-mcp-view-setup.sh
	install -d -m 755 /usr/share/containers/oci/hooks.d
	install -m 644 host/three/vps-mcp-stgview-poststart.json /usr/share/containers/oci/hooks.d/
	install -m 644 host/three/vps-mcp-stgview-poststop.json  /usr/share/containers/oci/hooks.d/
	install -d -m 755 /etc/containers/containers.conf.d
	install -m 644 host/three/vps-mcp-hooks.conf /etc/containers/containers.conf.d/vps-mcp-hooks.conf
	for u in vps-mcp-containers.service vps-mcp-view.service vps-mcp-stgmail.path \
	         vps-mcp-stgmail.service vps-mcp-stgmail-retry.service vps-mcp-stgmail-retry.timer; do \
	    install -m 644 host/systemd/$$u /etc/systemd/system/; \
	done
	install -d -m 755 -o nobody -g nobody /var/spool/vps-mcp-stgmail
	grep -q '^stgcapture:' /etc/aliases || echo 'stgcapture: /var/spool/vps-mcp-stgmail/' >> /etc/aliases
	newaliases
	postconf -e "recipient_delimiter = +"
	systemctl daemon-reload
	systemctl enable --now vps-mcp-containers.service vps-mcp-view.service \
	    vps-mcp-stgmail.path vps-mcp-stgmail-retry.timer
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
# Usage: cp example.com.dns example.org.dns; vi example.org.dns; make example.org.dnsdone
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
# Usage: make test.example.org__alice@example.com.done   (container test.example.org-web)
#        make example.net__bob@example.com.done         (domain apex: example.net-web)
#        make oauth.example.org__admin@example.com.done  (GitHub-login broker; needs
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

# podman_run FQDN EMAIL EXTRA — create <FQDN>-web with the options every
# container shares (%.done and %.create3). The journal gets a volume of its
# own: in systemd mode Podman would otherwise mount a tmpfs on /var/log/journal
# and the logs would be lost on every restart.
podman_run = podman run -d \
    --name     $(1)-web \
    --hostname $(1) \
    --network  vpsmcp-net \
    --systemd  always \
    --restart  always \
    --memory   1g \
    --pids-limit 200 \
    --cap-drop NET_RAW,NET_ADMIN \
    --env      SUBDOMAIN=$(1) \
    --env      MAIL_DOMAIN=$(1) \
    --env      NOTIFY_EMAIL=$(2) \
    -v         $(1)-journal:/var/log/journal \
    $(3) \
    $(IMAGE)

# wait_proxy FQDN — wait until the proxy routes the HTTP-01 path to FQDN.
define wait_proxy
	@echo "Waiting for the proxy to route the HTTP-01 path to $(1)..."
	@for i in $$(seq 60); do \
	    code=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
	        --resolve $(1):80:$(IP) \
	        http://$(1)/.well-known/acme-challenge/ping 2>/dev/null || true); \
	    if [ "$$code" = "404" ] || [ "$$code" = "200" ]; then \
	        echo "proxy ready (HTTP $$code) after $$i attempt(s)"; break; \
	    fi; \
	    sleep 2; \
	done
endef

# check_fqdn FQDN — FQDN must be a registered domain or one label below one.
define check_fqdn
	@d=$$(awk -v h="$(1)" '(h == $$0 || substr(h, length(h) - length($$0)) == "." $$0) && length($$0) > length(best) { best = $$0 } END { print best }' /etc/vps-mcp/domains 2>/dev/null); \
	test -n "$$d" || { echo "Error: $(1) is in no registered domain.  Run make <domain>.dnsdone first."; exit 1; }; \
	h="$(1)"; sub=$${h%"$$d"}; sub=$${sub%.}; \
	case "$$sub" in *.*) echo "Error: $(1) is more than one label below $$d."; exit 1;; esac
endef

%.done:
	$(eval _FQDN  := $(shell echo '$(call fqdn_of,$*)' | tr A-Z a-z))
	$(eval _EMAIL := $(call email_of,$*))
	$(eval _FWD   := $(call fwd_of,$*))
	$(eval _OAUTH := $(filter oauth.%,$(_FQDN)))
	@test -n "$(_EMAIL)" || \
	    { echo "Error: format is  [<old server IP>__]<hostname>__<email>.done  e.g. test.example.org__alice@example.com.done"; exit 1; }
	$(call check_fwd,$(_FWD))
	@test -z "$(_FWD)" || test -z "$(_OAUTH)" || \
	    { echo "Error: the GitHub-login broker cannot start in forward mode."; exit 1; }
	@test -n "$(IP)" || \
	    { echo "Error: IP not set.  Run make <IP>.setupdone first."; exit 1; }
	$(call check_fqdn,$(_FQDN))
	@test -z "$(_OAUTH)" || test -f /etc/vps-mcp/oauth.env || \
	    { echo "Error: create /etc/vps-mcp/oauth.env (mode 600) with GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET before making the oauth container."; exit 1; }
	@test -z "$(_OAUTH)" || test -z "$(OAUTH_HOST)" || test "$(OAUTH_HOST)" = "$(_FQDN)" || \
	    { echo "Error: this host already has a GitHub-login broker ($(OAUTH_HOST)); only one is allowed."; exit 1; }
	@test -n "$(_OAUTH)" || test -n "$(OAUTH_HOST)" || \
	    { echo "Error: no GitHub-login broker yet.  Create it first: make oauth.<domain>__<email>.done"; exit 1; }
	$(if $(_OAUTH),sed -i '/^OAUTH_HOST=/d' /etc/vps-mcp/host.env && echo "OAUTH_HOST=$(_FQDN)" >> /etc/vps-mcp/host.env)
	$(call podman_run,$(_FQDN),$(_EMAIL),--env OAUTH_BASE=https://$(if $(_OAUTH),$(_FQDN),$(OAUTH_HOST)) $(if $(_OAUTH),--env-file /etc/vps-mcp/oauth.env,) $(if $(_FWD),--env FORWARD=$(_FWD)))
	@echo "Letting the proxy refresh its routing table for the new container..."
	@sleep 10
	$(call wait_proxy,$(_FQDN))
	podman exec $(_FQDN)-web /usr/local/bin/vps-mcp-init.sh
	@touch $@

# ── three-container sets ──────────────────────────────────────────────────────
# Usage: make shop.example.org__alice@example.com.create3
#        make shop.example.org.dev2stg
#        make shop.example.org.stg2prod
#        make shop.example.org.list3
#
# One application gets three containers (stem = production hostname):
#   shop.example.org          production   no MCP   ROLE=prod
#   shop-stg.example.org  staging      no MCP   ROLE=stg
#   shop-dev.example.org      development  MCP      ROLE=dev
# (for a domain apex example.org: stg.example.org and dev.example.org). Claude works only
# in the dev container and commits to its /srv/app; a person on the host sends
# that commit to staging (dev2stg), then staging's commit to production
# (stg2prod), and each runs `make -C /srv/app install` there. Claude's trial and
# error therefore never reaches production. The dev container also sees the
# staging filesystem read-only at /mnt/stg (OCI hook, see install-services)
# and copies of staging's outgoing mail in /srv/stg-mail.
#
# After every transfer the dev repository records refs/remotes/stg/main and
# refs/remotes/prod/main, so Claude can tell what each server runs.

%.create3:
	$(call names3,$(call fqdn_of,$*))
	$(eval _EMAIL := $(call email_of,$*))
	$(eval _FWD   := $(call fwd_of,$*))
	@test -n "$(_EMAIL)" || \
	    { echo "Error: format is  [<old server IP>__]<production hostname>__<email>.create3  e.g. shop.example.org__alice@example.com.create3"; exit 1; }
	$(call check_fwd,$(_FWD))
	@test -n "$(IP)" || \
	    { echo "Error: IP not set.  Run make <IP>.setupdone first."; exit 1; }
	@test -n "$(OAUTH_HOST)" || \
	    { echo "Error: no GitHub-login broker yet.  Create it first: make oauth.<domain>__<email>.done"; exit 1; }
	$(call check_fqdn,$(_P))
	$(call check_fqdn,$(_S))
	$(call check_fqdn,$(_D))
	@for c in $(_P) $(_S) $(_D); do \
	    ! podman container exists $$c-web || { echo "Error: container $$c-web already exists."; exit 1; }; \
	done
	@systemctl is-active --quiet vps-mcp-view.service || \
	    { echo "Error: vps-mcp-view.service is not active.  Run make install-services first."; exit 1; }
	mkdir -p /run/vps-mcp/view/$(_S)
	$(call podman_run,$(_P),$(_EMAIL),--env ROLE=prod $(if $(_FWD),--env FORWARD=$(_FWD)))
	$(call podman_run,$(_S),$(_EMAIL),--env ROLE=stg)
	$(call podman_run,$(_D),$(_EMAIL),--env ROLE=dev $(if $(_FWD),--env FORWARD=$(_FWD)) --env OAUTH_BASE=https://$(OAUTH_HOST) -v /run/vps-mcp/view/$(_S):/mnt/stg:ro$(,)rslave -v $(_S)-journal:/mnt/stg-journal:ro)
	@echo "Letting the proxy refresh its routing table for the new containers..."
	@sleep 10
	$(call wait_proxy,$(_P))
	$(call wait_proxy,$(_S))
	$(call wait_proxy,$(_D))
	podman exec $(_P)-web /usr/local/bin/vps-mcp-init.sh
	podman exec $(_S)-web /usr/local/bin/vps-mcp-init.sh
	podman exec $(_D)-web /usr/local/bin/vps-mcp-init.sh
	@$(MAKE) --no-print-directory $(_P).dev2stg
	@$(MAKE) --no-print-directory $(_P).stg2prod YES=1
	@touch $@

# Send dev's committed HEAD to staging and install it there. Staging follows
# whatever is sent (it may move backwards, e.g. a hotfix branched from
# prod/main), but stops if staging's /srv/app was edited by hand.
%.dev2stg:
	$(call names3,$*)
	@set -e; \
	for c in $(_D) $(_S); do \
	    podman container exists $$c-web || { echo "Error: container $$c-web not found."; exit 1; }; \
	done; \
	if [ -n "$$(podman exec $(_D)-web git -C /srv/app status --porcelain)" ]; then \
	    echo "Error: $(_D) has uncommitted changes in /srv/app (only committed HEAD is sent):"; \
	    podman exec $(_D)-web git -C /srv/app status --short; \
	    echo "Ask Claude to commit (or discard) them first."; exit 1; \
	fi; \
	echo "==> $(_D)-web  ->  $(_S)-web"; \
	h=$$(podman exec $(_D)-web git -C /srv/app bundle create -q - HEAD \
	     | podman exec -i $(_S)-web /usr/local/bin/vps-mcp-recv.sh stg); \
	podman exec $(_D)-web git -C /srv/app update-ref refs/remotes/stg/main $$h; \
	echo "    stg/main = $$(podman exec $(_D)-web git -C /srv/app log -1 --format='%h %s' $$h)"; \
	echo "==> make install on $(_S)-web"; \
	podman exec $(_S)-web make -C /srv/app install

# Send staging's HEAD to production and install it there, after showing the
# commits and changed files production will receive (DIFF=1: the full diff)
# and asking for confirmation (YES=1 skips the question; create3 uses it for
# the skeleton). If production already runs staging's HEAD (e.g. an install
# that failed on a missing local file), only make install runs again.
# Production only fast-forwards and stops if its /srv/app was edited by hand.
%.stg2prod:
	$(call names3,$*)
	@set -e; \
	for c in $(_D) $(_S) $(_P); do \
	    podman container exists $$c-web || { echo "Error: container $$c-web not found."; exit 1; }; \
	done; \
	sh=$$(podman exec $(_S)-web git -C /srv/app rev-parse HEAD); \
	ph=$$(podman exec $(_P)-web git -C /srv/app rev-parse -q --verify HEAD || true); \
	dh=$$(podman exec $(_D)-web git -C /srv/app rev-parse HEAD); \
	same=; [ "$$sh" = "$$ph" ] && same=1; \
	if [ -n "$$same" ]; then \
	    echo "== production already runs staging's HEAD ($$(podman exec $(_S)-web git -C /srv/app log -1 --format='%h %s')):"; \
	    echo "   nothing to send; make install runs again (it is idempotent)"; \
	elif [ -n "$$ph" ]; then \
	    echo "== commits going to production (staging's HEAD, tested there):"; \
	    podman exec $(_S)-web git -C /srv/app log --oneline $$ph..HEAD || \
	        { echo "Error: production's HEAD is not in staging's history."; exit 1; }; \
	    podman exec $(_S)-web git -C /srv/app --no-pager diff --stat $$ph HEAD; \
	    if [ "$(DIFF)" = 1 ]; then \
	        echo "== diff (production -> staging):"; \
	        podman exec $(_S)-web git -C /srv/app --no-pager diff $$ph HEAD; \
	    else \
	        echo "   (full diff: make $*.stg2prod DIFF=1)"; \
	    fi; \
	else \
	    echo "== first deploy to $(_P)"; \
	fi; \
	if [ "$$dh" != "$$sh" ]; then \
	    echo; \
	    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; \
	    echo "!! WARNING: dev has changed since staging was updated. These changes"; \
	    echo "!! are NOT deployed (run $*.dev2stg and test on staging first):"; \
	    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; \
	    podman exec $(_D)-web git -C /srv/app log --oneline $$sh..$$dh || true; \
	    podman exec $(_D)-web git -C /srv/app --no-pager diff --stat $$sh $$dh || true; \
	    podman exec $(_D)-web git -C /srv/app --no-pager diff $$sh $$dh || true; \
	    echo "!! (end of changes NOT deployed)"; \
	    echo; \
	fi; \
	if [ "$(YES)" != 1 ]; then \
	    printf 'Deploy to %s? [y/N] ' "$(_P)"; read a; \
	    [ "$$a" = y ] || { echo "aborted"; exit 1; }; \
	fi; \
	if [ -z "$$same" ]; then \
	    echo "==> $(_S)-web  ->  $(_P)-web"; \
	    h=$$(podman exec $(_S)-web git -C /srv/app bundle create -q - HEAD \
	         | podman exec -i $(_P)-web /usr/local/bin/vps-mcp-recv.sh prod); \
	    podman exec $(_D)-web git -C /srv/app update-ref refs/remotes/prod/main $$h; \
	    echo "    prod/main = $$(podman exec $(_D)-web git -C /srv/app log -1 --format='%h %s' $$h)"; \
	fi; \
	echo "==> make install on $(_P)-web"; \
	podman exec $(_P)-web make -C /srv/app install

# Status and git HEAD of the three containers, then dev's recent history with
# the stg/main and prod/main markers.
%.list3:
	$(call names3,$*)
	@for c in $(_P) $(_S) $(_D); do \
	    if podman container exists $$c-web; then \
	        st=$$(podman inspect -f '{{.State.Status}}' $$c-web); \
	        hd=$$(podman exec $$c-web git -C /srv/app log -1 --format='%h %s' 2>/dev/null || echo '-'); \
	        printf '%-40s %-9s %s\n' "$$c-web" "$$st" "$$hd"; \
	    else \
	        printf '%-40s (missing)\n' "$$c-web"; \
	    fi; \
	done; \
	echo; \
	podman exec $(_P)-web /usr/local/bin/vps-mcp-mode.sh status 2>/dev/null | sed 's/^/$(_P): /' || true; \
	echo; \
	podman exec $(_D)-web git -C /srv/app log --oneline --decorate --all -10 2>/dev/null || true

# ── certificate and forward mode (moving a site from an old server) ──────────
# Usage: make 203.0.113.5__example.net__alice@example.com.done      (or .create3)
#        ... point the domain's DNS at this host ...
#        make example.net.getcert
#        make example.net.unforward
#
# A container created with a leading IP starts in forward mode: port 443 is
# passed through, still encrypted, to that old server (which keeps serving with
# its own certificate), and port 80 proxies to it except for ACME challenges.
# The container can therefore obtain its own certificate as soon as DNS points
# here, without the site going down. unforward then lets the container serve
# 443; what it does not serve yet still goes to the old server through
# app.d/forward.conf (seeded at creation; for a create3 set it lives in the dev
# repository and reaches production with dev2stg / stg2prod), which Claude
# narrows as parts move. All of this runs inside the container
# (vps-mcp-mode.sh); the host only runs podman exec.
#
#   <host>.getcert     Let's Encrypt certificate for <host> plus, on a
#                      production / standalone container, the names in its
#                      /etc/vps-mcp/cert-names (one certificate). Re-run when
#                      a name is added or a first attempt failed.
#   <host>.unforward   leave forward mode (refused without a valid certificate)
#   <host>.forward     back to forward mode; OLD=<IP> changes the target
#   <host>.mode        show mode, forward target and certificate
%.getcert:
	@podman container exists $*-web || { echo "Error: container $*-web not found."; exit 1; }
	podman exec $*-web /usr/local/bin/vps-mcp-mode.sh getcert $(if $(NOCHECK),--no-check)
	@podman exec $*-web /usr/local/bin/vps-mcp-mode.sh status

%.unforward:
	@podman container exists $*-web || { echo "Error: container $*-web not found."; exit 1; }
	podman exec $*-web /usr/local/bin/vps-mcp-mode.sh unforward
	@podman exec $*-web /usr/local/bin/vps-mcp-mode.sh status

%.forward:
	@podman container exists $*-web || { echo "Error: container $*-web not found."; exit 1; }
	$(call check_fwd,$(OLD))
	podman exec $*-web /usr/local/bin/vps-mcp-mode.sh forward $(OLD)
	@podman exec $*-web /usr/local/bin/vps-mcp-mode.sh status

%.mode:
	@podman exec $*-web /usr/local/bin/vps-mcp-mode.sh status

# ── list ──────────────────────────────────────────────────────────────────────

list:
	@podman ps -a --filter "name=-web" --format "{{.Names}}\t{{.Status}}" | \
	awk -F'\t' 'NR == FNR { dom[NR] = $$0; nd = NR; next } \
	    { h = $$1; sub(/-web$$/, "", h); best = "(unregistered)"; \
	      for (i = 1; i <= nd; i++) { d = dom[i]; \
	          if ((h == d || substr(h, length(h) - length(d)) == "." d) && length(d) > length(b2)) { best = d; b2 = d } } \
	      b2 = ""; print best "\t" $$0 }' /etc/vps-mcp/domains - | sort | \
	awk -F'\t' '$$1 != prev { print "\n" $$1; prev = $$1 } { printf "  %-40s %s\n", $$2, $$3 }'

# ── MCP app update ─────────────────────────────────────────────────────────────
# The MCP app (index.mjs + its node_modules) is baked into the image and copied
# into each container's writable layer at build time. Updating therefore has two
# independent scopes, and a full rollout needs BOTH:
#
#   make image          rebuilds the image  → ONLY containers created afterwards.
#   make mcpupdate       patches every already-running container IN PLACE.
#   make <sub>.mcpupdate patches one running container (e.g. make test.example.org.mcpupdate).
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
	    h=$${c%-web}; \
	    : 'Staging/production of a create3 set run no MCP server; the set is'; \
	    : 'updated through its dev container, which this loop also visits.'; \
	    case $$h in *-stg.*|stg.*) continue ;; esac; \
	    d=$$(sh scripts/names3.sh $$h | cut -d' ' -f3); \
	    podman container exists $$d-web && continue; \
	    $(MAKE) --no-print-directory $$h.mcpupdate MCPUPDATE_ALL=1; \
	done; \
	: 'Every container, staging and production included, runs the scripts.'; \
	for c in $$cs; do $(MAKE) --no-print-directory $${c%-web}.scriptupdate; done

# ── check installed files vs this checkout ───────────────────────────────────
# Reports OK / DIFFER / MISSING for every host-side file the Makefile installs,
# plus the image-baked MCP app if podman + the image are present. Replays
# template substitutions (DOMAIN, BIND paths, proxy UIDs) so the comparison is
# meaningful. Especially useful for configs no update target refreshes — proxy
# units, nftables, opendkim, BIND — so a `git pull` doesn't silently leave the
# live host on an old copy. Then, for every running <name>-web container, diffs
# the baked nginx/systemd/init files (`mcpupdate` refreshes only the helper
# scripts in /usr/local/bin, not the nginx configuration) and
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
#   make test.example.org.check   → test.example.org-web
%.check:
	@VERBOSE=1 sh scripts/check-installed.sh $*-web

# Refresh the image's helper scripts, their pristine nginx snippets and the
# app skeleton inside one running container (stem -> <stem>-web), plus the
# tools they need (dig, ...). Unlike the MCP app these run on every container,
# staging and production included: vps-mcp-mode.sh (getcert / forward /
# unforward), vps-mcp-recv.sh (dev2stg / stg2prod), certbot-deploy.sh, and
# vps-mcp-init.sh (used only at creation, refreshed for consistency).
# make mcpupdate runs it for every container; <stem>.mcpupdate for the
# containers of that stem's set.
%.scriptupdate:
	@set -e; c="$*-web"; \
	podman container exists $$c || { echo "Error: container $$c not found."; exit 1; }; \
	for f in vps-mcp-init.sh certbot-deploy.sh vps-mcp-recv.sh vps-mcp-mode.sh; do \
	    podman cp container/systemd/$$f $$c:/usr/local/bin/$$f; \
	    podman exec $$c chmod 755 /usr/local/bin/$$f; \
	done; \
	podman exec $$c mkdir -p /usr/local/share/vps-mcp/nginx; \
	for f in listen443.conf listen443-main.conf http80-default.conf; do \
	    podman cp container/nginx/$$f $$c:/usr/local/share/vps-mcp/nginx/$$f; \
	done; \
	podman exec $$c rm -rf /usr/local/share/vps-mcp/app-skeleton; \
	podman cp container/app-skeleton $$c:/usr/local/share/vps-mcp/app-skeleton; \
	sh scripts/ensure-tools.sh $$c; \
	echo "    $$c: scripts updated"

# Update one running container in place. Stem is the hostname:
#   make test.example.org.mcpupdate   → test.example.org-web
#   make oauth.example.org.mcpupdate  → oauth.example.org-web
%.mcpupdate:
	@set -e; \
	c="$*-web"; \
	case "$*" in *-stg.*|stg.*) echo "$$c: staging container (no MCP); skipped."; exit 0 ;; esac; \
	d=$$(sh scripts/names3.sh $* | cut -d' ' -f3); \
	if podman container exists $$d-web; then \
	    echo "$$c is the production container of a create3 set; updating its dev container $$d-web."; \
	    c="$$d-web"; \
	fi; \
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
	echo "    $$c updated"; \
	: 'Called directly (not from mcpupdate): the scripts of the whole set too.'; \
	if [ -z "$(MCPUPDATE_ALL)" ]; then \
	    for x in $$(sh scripts/names3.sh $*); do \
	        if podman container exists $$x-web; then $(MAKE) --no-print-directory $$x.scriptupdate; fi; \
	    done; \
	fi
