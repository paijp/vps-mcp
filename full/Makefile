# https://github.com/paijp/vps-mcp
#
# vps-mcp full — single-host MCP server setup
#
# Usage (run once as root):
#   make 203.0.113.1__example.com__admin@example.com.setupdone

# After %.setupdone runs, DOMAIN/IP/EMAIL are stored in /etc/vps-mcp/host.env.
DOMAIN ?= $(shell grep '^DOMAIN=' /etc/vps-mcp/host.env 2>/dev/null | cut -d= -f2)
IP     ?= $(shell grep '^IP='     /etc/vps-mcp/host.env 2>/dev/null | cut -d= -f2)
EMAIL  ?= $(shell grep '^EMAIL='  /etc/vps-mcp/host.env 2>/dev/null | cut -d= -f2)

word1_of = $(word 1,$(subst __, ,$(1)))
word2_of = $(word 2,$(subst __, ,$(1)))
word3_of = $(word 3,$(subst __, ,$(1)))

.DEFAULT_GOAL := help
.PHONY: help mcpupdate

# ── help ──────────────────────────────────────────────────────────────────────

help:
	@printf "vps-mcp full — single-host MCP server\n\n"
	@printf "Setup (run once as root):\n"
	@printf "  make 203.0.113.1__example.com__admin@example.com.setupdone\n"
	@printf "      Swapfile, BIND wildcard DNS, nginx, Node.js 22, MCP server,\n"
	@printf "      certbot (waits for DNS propagation), firewall, auto-updates,\n"
	@printf "      memory-pressure hardening (zram, persistent journal).\n"
	@printf "      Also writes an /etc/vps-mcp/oauth.env template.\n\n"
	@printf "  Then fill GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET in\n"
	@printf "  /etc/vps-mcp/oauth.env (GitHub OAuth App callback\n"
	@printf "  https://<DOMAIN>/mcp/callback) and run:\n"
	@printf "  make oauth.done\n"
	@printf "      Applies the credentials (restarts mcp-server).\n\n"
	@printf "Update an already-set-up host (after git pull):\n"
	@printf "  make mcpupdate\n"
	@printf "      Stops mcp-server, reinstalls /opt/mcp (index.mjs,\n"
	@printf "      package.json+deps), the systemd unit and /srv/deploy, then\n"
	@printf "      restarts it. Does not touch the nginx config (certbot owns TLS).\n\n"
	@printf "Variables (auto-read from /etc/vps-mcp/host.env after setupdone):\n"
	@printf "  DOMAIN  IP  EMAIL\n"

# ── host setup ────────────────────────────────────────────────────────────────
# Usage: make 203.0.113.1__example.com__admin@example.com.setupdone
#
# stem format: IP__DOMAIN__EMAIL

%.setupdone:
	$(eval _IP     := $(call word1_of,$*))
	$(eval _DOMAIN := $(call word2_of,$*))
	$(eval _EMAIL  := $(call word3_of,$*))
	@test -n "$(_IP)"     || { echo "Error: format is  IP__DOMAIN__EMAIL.setupdone"; exit 1; }
	@test -n "$(_DOMAIN)" || { echo "Error: format is  IP__DOMAIN__EMAIL.setupdone"; exit 1; }
	@test -n "$(_EMAIL)"  || { echo "Error: format is  IP__DOMAIN__EMAIL.setupdone"; exit 1; }

	# ── swapfile ────────────────────────────────────────────────────────────
	if [ ! -f /swapfile ]; then \
	    fallocate -l 1G /swapfile; \
	    chmod og-rwx /swapfile; \
	    mkswap /swapfile; \
	    swapon /swapfile; \
	    echo '/swapfile none swap sw 0 0' >> /etc/fstab; \
	fi

	# ── hostname & host.env ─────────────────────────────────────────────────
	hostnamectl set-hostname $(_DOMAIN)
	mkdir -p /etc/vps-mcp
	printf 'DOMAIN=%s\nIP=%s\nEMAIL=%s\nSUBDOMAIN=%s\nNOTIFY_EMAIL=%s\n' \
	    "$(_DOMAIN)" "$(_IP)" "$(_EMAIL)" "$(_DOMAIN)" "$(_EMAIL)" \
	    > /etc/vps-mcp/host.env

	# ── packages ────────────────────────────────────────────────────────────
	if command -v apt-get >/dev/null 2>&1; then \
	    apt-get update; \
	    apt-get upgrade -y; \
	    apt-get install -y nginx certbot python3-certbot-nginx \
	        bind9 postfix opendkim opendkim-tools unattended-upgrades \
	        curl; \
	elif command -v dnf >/dev/null 2>&1; then \
	    dnf install -y epel-release 2>/dev/null || \
	        dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$$(rpm -E %rhel).noarch.rpm" 2>/dev/null || true; \
	    dnf upgrade -y; \
	    dnf install -y nginx certbot python3-certbot-nginx \
	        bind bind-utils postfix opendkim opendkim-tools dnf-automatic \
	        curl; \
	else echo "Error: no supported package manager"; exit 1; fi

	# ── Node.js 22 (NodeSource) ─────────────────────────────────────────────
	curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - 2>/dev/null || \
	    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>/dev/null || true
	if command -v dnf >/dev/null 2>&1; then \
	    dnf install -y nodejs; \
	else \
	    apt-get install -y nodejs; \
	fi

	# ── BIND9 ───────────────────────────────────────────────────────────────
	if command -v apt-get >/dev/null 2>&1; then \
	    BIND_ZONE_DIR=/etc/bind/zones; \
	    BIND_CONF=/etc/bind/named.conf.local; \
	elif command -v dnf >/dev/null 2>&1; then \
	    BIND_ZONE_DIR=/var/named; \
	    mkdir -p /etc/named; \
	    BIND_CONF=/etc/named/named.conf.local; \
	    install -m 644 host/bind/named.conf.tmpl /etc/named.conf; \
	fi; \
	mkdir -p $$BIND_ZONE_DIR; \
	sed -e 's|__IP__|$(_IP)|g' \
	    -e 's|__DOMAIN__|$(_DOMAIN)|g' \
	    -e "s|__SERIAL__|$$(date +%Y%m%d01)|g" \
	    host/bind/zone.tmpl > $$BIND_ZONE_DIR/$(_DOMAIN).zone; \
	sed -e 's|__DOMAIN__|$(_DOMAIN)|g' \
	    -e "s|__BIND_ZONE_DIR__|$$BIND_ZONE_DIR|g" \
	    host/bind/named.conf.local.tmpl > $$BIND_CONF; \
	chgrp named $$BIND_ZONE_DIR/$(_DOMAIN).zone $$BIND_CONF 2>/dev/null || true; \
	chmod 640  $$BIND_ZONE_DIR/$(_DOMAIN).zone $$BIND_CONF 2>/dev/null || true
	systemctl enable --now named 2>/dev/null || systemctl enable --now bind9
	rndc reload 2>/dev/null || true
	rndc notify 2>/dev/null || true

	# ── opendkim ────────────────────────────────────────────────────────────
	mkdir -p /etc/opendkim/keys/$(_DOMAIN); \
	if [ ! -f /etc/opendkim/keys/$(_DOMAIN)/mail.private ]; then \
	    opendkim-genkey -b 2048 -D /etc/opendkim/keys/$(_DOMAIN)/ -d $(_DOMAIN) -s mail; \
	    chown -R opendkim:opendkim /etc/opendkim/keys; \
	fi; \
	if command -v apt-get >/dev/null 2>&1; then _ZF=/etc/bind/zones/$(_DOMAIN).zone; else _ZF=/var/named/$(_DOMAIN).zone; fi; \
	grep -qF 'mail._domainkey' $$_ZF || cat /etc/opendkim/keys/$(_DOMAIN)/mail.txt >> $$_ZF; \
	grep -qF 'v=spf1'          $$_ZF || printf '@   IN TXT "v=spf1 a mx ip4:$(_IP) ~all"\n'                             >> $$_ZF; \
	grep -qF 'v=DMARC1'        $$_ZF || printf '_dmarc  IN TXT "v=DMARC1; p=none; rua=mailto:postmaster@$(_DOMAIN)"\n' >> $$_ZF; \
	rndc reload 2>/dev/null || true; \
	sed 's|__DOMAIN__|$(_DOMAIN)|g' host/opendkim/opendkim.conf.tmpl > /etc/opendkim.conf; \
	systemctl enable --now opendkim

	# ── postfix ─────────────────────────────────────────────────────────────
	postconf -e "inet_interfaces = all"
	postconf -e "inet_protocols = ipv4"
	postconf -e "myhostname = $(_DOMAIN)"
	postconf -e "myorigin = $(_DOMAIN)"
	postconf -e "smtpd_relay_restrictions = permit_mynetworks reject_unauth_destination"
	postconf -e "smtpd_milters = inet:127.0.0.1:8891"
	postconf -e "non_smtpd_milters = inet:127.0.0.1:8891"
	postconf -e "milter_protocol = 6"
	postconf -e "milter_default_action = accept"
	systemctl enable --now postfix

	# ── auto security updates + weekly reboot ───────────────────────────────
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
	# zram swap: dnf-automatic and Node.js are memory-hungry; on a small host
	# they can push the machine into disk-swap thrash (CPU + I/O pinned, SSH
	# dead). Compressed in-RAM swap absorbs those spikes far more gracefully than
	# the on-disk /swapfile above.
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

	# ── firewall ────────────────────────────────────────────────────────────
	if command -v firewall-cmd >/dev/null 2>&1; then \
	    systemctl enable --now firewalld; \
	    for svc in ssh http https; do firewall-cmd --permanent --add-service=$$svc; done; \
	    for port in 53/udp 53/tcp; do firewall-cmd --permanent --add-port=$$port; done; \
	    firewall-cmd --reload; \
	elif command -v ufw >/dev/null 2>&1; then \
	    ufw allow ssh; ufw allow http; ufw allow https; \
	    ufw allow 53/udp; ufw allow 53/tcp; \
	    ufw --force enable; \
	fi

	# ── nginx ───────────────────────────────────────────────────────────────
	mkdir -p /etc/nginx/ssl
	if [ ! -f /etc/nginx/ssl/fullchain.pem ]; then \
	    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
	        -keyout /etc/nginx/ssl/privkey.pem \
	        -out    /etc/nginx/ssl/fullchain.pem \
	        -subj "/CN=$(_DOMAIN)"; \
	fi
	if command -v apt-get >/dev/null 2>&1; then \
	    NGINX_CONF_DIR=/etc/nginx/sites-available; \
	    install -m 644 nginx/vps-mcp.conf $$NGINX_CONF_DIR/vps-mcp.conf; \
	    sed -i 's|__DOMAIN__|$(_DOMAIN)|g' $$NGINX_CONF_DIR/vps-mcp.conf; \
	    ln -sf $$NGINX_CONF_DIR/vps-mcp.conf /etc/nginx/sites-enabled/vps-mcp.conf; \
	    rm -f /etc/nginx/sites-enabled/default; \
	else \
	    NGINX_CONF_DIR=/etc/nginx/conf.d; \
	    install -m 644 nginx/vps-mcp.conf $$NGINX_CONF_DIR/vps-mcp.conf; \
	    sed -i 's|__DOMAIN__|$(_DOMAIN)|g' $$NGINX_CONF_DIR/vps-mcp.conf; \
	fi
	systemctl enable --now nginx
	nginx -t && systemctl reload nginx

	# ── MCP server (Node.js) ─────────────────────────────────────────────────
	# Install/refresh the MCP app via the shared mcpupdate target (same logic
	# used to update an already-set-up host).
	mkdir -p /opt/mcp
	$(MAKE) --no-print-directory mcpupdate

	# ── MCP credentials ──────────────────────────────────────────────────────
	# The Bearer token is minted dynamically after a successful GitHub login;
	# only its sha256 hash is ever written here (by the MCP server at login).
	mkdir -p /etc/mcp-server
	chmod 700 /etc/mcp-server
	# GitHub OAuth App credentials. A mode-600 template is created on first run;
	# fill in the real GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET, then restart
	# mcp-server (systemctl restart mcp-server). Register the OAuth App with
	# Homepage https://$(_DOMAIN) and callback https://$(_DOMAIN)/mcp/callback.
	if [ ! -e /etc/vps-mcp/oauth.env ]; then \
	    printf 'GITHUB_CLIENT_ID=\nGITHUB_CLIENT_SECRET=\n' > /etc/vps-mcp/oauth.env; \
	    chmod 600 /etc/vps-mcp/oauth.env; \
	    echo "Created /etc/vps-mcp/oauth.env template — fill in GitHub OAuth App credentials (callback https://$(_DOMAIN)/mcp/callback), then 'make oauth.done'."; \
	fi

	# ── certbot (wait for DNS propagation then run) ───────────────────────────
	mkdir -p /etc/letsencrypt/renewal-hooks/deploy
	install -m 755 systemd/certbot-deploy.sh /etc/letsencrypt/renewal-hooks/deploy/vps-mcp.sh
	for i in $$(seq 1 30); do \
	    RESOLVED=$$(dig +short "$(_DOMAIN)" | tail -1); \
	    if [ "$$RESOLVED" = "$(_IP)" ]; then \
	        certbot --nginx --non-interactive --agree-tos \
	            --email "$(_EMAIL)" -d "$(_DOMAIN)" || true; \
	        break; \
	    fi; \
	    echo "certbot: waiting for DNS ($(_DOMAIN) → $(_IP), got $$RESOLVED) [$$i/30]"; \
	    sleep 60; \
	done

	# ── enable MCP server on boot ────────────────────────────────────────────
	# mcpupdate above already started it; just enable boot start. GitHub login
	# (and the only notification email) happens later, once oauth.env is filled
	# in and `make oauth.done` is run. No email is sent at setup time.
	systemctl enable mcp-server

	@touch $@
	@printf "\nSetup complete: https://$(_DOMAIN)/mcp/sse\n"
	@printf "Next: set GITHUB_CLIENT_ID/GITHUB_CLIENT_SECRET in /etc/vps-mcp/oauth.env\n"
	@printf "(GitHub OAuth App callback: https://$(_DOMAIN)/mcp/callback), then: make oauth.done\n"

# ── apply GitHub OAuth credentials ────────────────────────────────────────────
# Second stage: after filling /etc/vps-mcp/oauth.env, run `make oauth.done` to
# restart the MCP server so the new credentials take effect. A real file target
# (not .PHONY): because it depends on oauth.env, editing that file makes it newer
# than oauth.done, so a later `make oauth.done` re-applies automatically.

# Ensure the template exists even if `make oauth.done` is run before setup
# (e.g. on a host configured by other means): create a mode-600 stub so the
# guard below can prompt for the missing values instead of a cryptic
# "No rule to make target" error.
/etc/vps-mcp/oauth.env:
	@mkdir -p /etc/vps-mcp
	@printf 'GITHUB_CLIENT_ID=\nGITHUB_CLIENT_SECRET=\n' > $@
	@chmod 600 $@
	@echo "Created $@ template — fill in GitHub OAuth App credentials, then: make oauth.done"

oauth.done: /etc/vps-mcp/oauth.env
	@grep -q '^GITHUB_CLIENT_ID=..*'     $< || { echo "Set GITHUB_CLIENT_ID in $<";     exit 1; }
	@grep -q '^GITHUB_CLIENT_SECRET=..*' $< || { echo "Set GITHUB_CLIENT_SECRET in $<"; exit 1; }
	systemctl restart mcp-server
	@touch $@
	@printf "OAuth applied. Connect via https://$(DOMAIN)/mcp/sse and log in with GitHub.\n"

# ── update MCP server code (git pull && make mcpupdate) ───────────────────────
# Refresh the MCP app from this checkout without re-running full host setup.
# Also invoked by %.setupdone so initial install and update share one path.
# The service is stopped first: with Restart=on-failure, a crash mid-update
# could otherwise auto-restart on half-written files / a partial npm install.
# Does NOT touch the nginx config: certbot rewrites TLS lines in the live conf,
# so overwriting it would revert HTTPS. If full/nginx/vps-mcp.conf changed,
# merge it into the live conf manually.
mcpupdate:
	-systemctl stop mcp-server
	mkdir -p /opt/mcp
	install -m 644 mcp/index.mjs    /opt/mcp/index.mjs
	install -m 644 mcp/package.json /opt/mcp/package.json
	cd /opt/mcp && npm install --omit=dev
	install -m 644 systemd/mcp-server.service /etc/systemd/system/
	mkdir -p /srv/deploy
	systemctl daemon-reload
	systemctl restart mcp-server
	@printf "mcpupdate: /opt/mcp refreshed and mcp-server restarted.\n"
	@printf "Note: nginx config not touched. If full/nginx/vps-mcp.conf changed,\n"
	@printf "merge it into the live /etc/nginx conf manually (certbot owns TLS lines).\n"
