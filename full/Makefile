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
.PHONY: help

# ── help ──────────────────────────────────────────────────────────────────────

help:
	@printf "vps-mcp full — single-host MCP server\n\n"
	@printf "Setup (run once as root):\n"
	@printf "  make 203.0.113.1__example.com__admin@example.com.setupdone\n"
	@printf "      Swapfile, BIND wildcard DNS, nginx, Node.js 22, MCP server,\n"
	@printf "      certbot (waits for DNS propagation), firewall, auto-updates.\n\n"
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
	fi
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
	mkdir -p /opt/mcp
	install -m 644 mcp/index.mjs    /opt/mcp/index.mjs
	install -m 644 mcp/package.json /opt/mcp/package.json
	cd /opt/mcp && npm ci --omit=dev
	install -m 644 systemd/mcp-server.service /etc/systemd/system/
	systemctl daemon-reload

	# ── MCP credentials ──────────────────────────────────────────────────────
	mkdir -p /etc/mcp-server
	chmod 700 /etc/mcp-server
	openssl rand -hex 8  > /etc/mcp-server/secret
	openssl rand -hex 32 > /etc/mcp-server/token
	chmod 600 /etc/mcp-server/secret /etc/mcp-server/token
	@printf "client_secret: $$(cat /etc/mcp-server/secret)\n"

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

	# ── start MCP server ─────────────────────────────────────────────────────
	systemctl enable --now mcp-server

	# ── creation notification ────────────────────────────────────────────────
	printf 'From: noreply@%s\r\nTo: %s\r\nSubject: created: %s\r\n\r\nVPS MCP server ready.\r\nMCP SSE endpoint: https://%s/mcp/sse\r\n' \
	    "$(_DOMAIN)" "$(_EMAIL)" "$(_DOMAIN)" "$(_DOMAIN)" \
	    | /usr/sbin/sendmail -f "noreply@$(_DOMAIN)" "$(_EMAIL)" || true

	@touch $@
	@printf "\nSetup complete: https://$(_DOMAIN)/mcp/sse\n"
