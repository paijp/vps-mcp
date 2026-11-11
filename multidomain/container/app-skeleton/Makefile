# Deploy this repository onto the container it is checked out in:
#     make -C /srv/app install
#
# The same commit is installed on development, staging and production (the
# host sends it with `make <fqdn>.dev2stg` / `make <fqdn>.stg2prod`), so this
# Makefile must work on a container that has only what the image provides plus
# what this repository installs. Keep it idempotent and stop on the first error.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

# files/ mirrors the filesystem: files/etc/nginx/app.d/x.conf is installed as
# /etc/nginx/app.d/x.conf. Directories listed here are mirrored exactly (a file
# deleted from the repository is deleted there too); everything else under
# files/ is copied over without deleting anything.
MIRROR_DIRS := etc/nginx/app.d opt/app.d

# Applications live in files/opt/app.d/<app>/ (installed to /opt/app.d/<app>/,
# mirrored). An application with per-server settings ships a template
# files/opt/app.d/<app>/env.py.sample; the real file is
# /opt/env.d/<app>/env.py. When it is missing, install creates the directory
# (750 root:ENV_GROUP), puts the template next to it as env.py.sample and stops;
# a person fills it in and renames it to env.py, once on staging and once on
# production. A template whose first lines contain "# env: auto" (no secrets)
# is installed as env.py without stopping; on the development container every
# template is.
APPS := $(notdir $(patsubst %/,%,$(wildcard files/opt/app.d/*/)))
ENV_APPS := $(foreach a,$(APPS),$(if $(wildcard files/opt/app.d/$(a)/env.py.sample),$(a)))

# Data directories whose state `make status` summarizes (file count, total
# size, newest change; never names or contents), e.g. /var/www/db/myapp.
STATUS_DIRS :=

# Group that may read /opt/env.d/<app>/ (directory 750, files 640, owner root):
# the user the applications run as.
ENV_GROUP := nginx

# Other per-environment files placed by hand on each server and never
# committed (passwords, API keys, ...). install stops if one is missing.
REQUIRED_LOCAL :=

ROLE := $(shell sed -n 's/^ROLE=//p' /etc/vps-mcp-env 2>/dev/null)

RSYNC := rsync -rlt --omit-dir-times --checksum --exclude=.gitkeep

.PHONY: install install-inner check files reload getlog diff status

# Run install-inner; on failure print diagnostics and still exit non-zero.
install:
	@$(MAKE) --no-print-directory install-inner || { \
	    echo '==== install FAILED; collecting diagnostics ===='; \
	    $(MAKE) --no-print-directory -k getlog; \
	    exit 1; }
	@echo '==== install OK ===='

install-inner: check files reload

check:
	@for f in files/opt/app.d/*/env.py; do \
	    test ! -e "$$f" || { echo "$$f: settings go in /opt/env.d/<app>/env.py, not in the repository"; exit 1; }; \
	done
	@missing=; \
	for a in $(ENV_APPS); do \
	    d=/opt/env.d/$$a; f=$$d/env.py; s=files/opt/app.d/$$a/env.py.sample; \
	    if test ! -e "$$f"; then \
	        install -d -m 750 -o root -g $(ENV_GROUP) "$$d"; \
	        if [ "$(ROLE)" = dev ] || head -n 5 "$$s" | grep -qi '^# *env: *auto'; then \
	            install -m 640 -o root -g $(ENV_GROUP) "$$s" "$$f"; \
	            echo "created $$f from env.py.sample"; \
	        else \
	            test -e "$$d/env.py.sample" || install -m 640 -o root -g $(ENV_GROUP) "$$s" "$$d/env.py.sample"; \
	            echo "missing $$f: fill in the template placed next to it, then rename it:"; \
	            echo "    cd $$d && vi env.py.sample && mv env.py.sample env.py"; \
	            missing=1; continue; \
	        fi; \
	    fi; \
	    p=$$(stat -c '%a %U:%G' "$$f"); \
	    [ "$$p" = "640 root:$(ENV_GROUP)" ] || { chown root:$(ENV_GROUP) "$$f" && chmod 640 "$$f" && \
	        echo "fixed $$f: was $$p, now 640 root:$(ENV_GROUP) (the application reads it as $(ENV_GROUP))"; }; \
	    for v in $$(sed -n 's/^\([A-Z_][A-Z0-9_]*\) *=.*/\1/p' "$$s"); do \
	        grep -q "^$$v *=" "$$f" || echo "warning: $$f has no $$v (see env.py.sample)"; \
	    done; \
	done; \
	test -z "$$missing"
	@for f in $(REQUIRED_LOCAL); do \
	    test -e "$$f" || { echo "missing $$f (place it by hand on this server)"; exit 1; }; \
	done

# Copy files/ into place; restore nginx's app.d if the result does not load.
files:
	rm -rf /var/tmp/app.d.bak
	cp -a /etc/nginx/app.d /var/tmp/app.d.bak
	for d in $(MIRROR_DIRS); do \
	    mkdir -p "/$$d"; \
	    $(RSYNC) --delete "files/$$d/" "/$$d/"; \
	done
	$(RSYNC) $(addprefix --exclude=/,$(MIRROR_DIRS)) files/ /
	nginx -t || { \
	    rm -rf /etc/nginx/app.d && mv /var/tmp/app.d.bak /etc/nginx/app.d; \
	    echo 'nginx -t failed; /etc/nginx/app.d restored'; exit 1; }

# On the development container a reload from here would cut the MCP
# connection, so it is left to the nginx_reload tool.
reload:
ifeq ($(ROLE),dev)
	@echo 'dev container: reload nginx with the nginx_reload tool'
else
	systemctl reload nginx
endif

getlog:
	-nginx -t
	-systemctl --failed --no-pager
	-journalctl -n 50 --no-pager
	-tail -n 30 /var/log/nginx/error.log

# Show what install would change (itemized, nothing is written).
diff:
	@for d in $(MIRROR_DIRS); do \
	    $(RSYNC) -n -i --delete "files/$$d/" "/$$d/"; \
	done
	@$(RSYNC) -n -i $(addprefix --exclude=/,$(MIRROR_DIRS)) files/ /

# State of this server as counts, sizes and timestamps only. The host runs it
# on production (make <fqdn>.prodstatus) and masks the output, so a person can
# paste it to Claude. Never print data here: no file names, log lines,
# records or identifiers.
UNITS := $(notdir $(wildcard files/etc/systemd/system/*.service))
status:
	@echo "role:      $(ROLE)   HEAD: $$(git log -1 --format='%h %s' 2>/dev/null)"
	@printf 'nginx -t:  '; nginx -t >/dev/null 2>&1 && echo ok || echo FAILED
	@echo "failed:    $$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l) unit(s)"
	@for u in $(UNITS); do \
	    printf 'unit:      %-28s %-9s since %s, errors in 24h: %s\n' "$$u" \
	        "$$(systemctl is-active $$u 2>/dev/null)" \
	        "$$(systemctl show $$u -p ActiveEnterTimestamp --value 2>/dev/null)" \
	        "$$(journalctl -u $$u -p err --since -24h -q --no-pager 2>/dev/null | wc -l)"; \
	done
	@f=/var/log/nginx/access.log; test -r $$f && \
	    echo "nginx:     last 1000 requests by status: $$(tail -n 1000 $$f | awk '{print $$9}' | sort | uniq -c | awk '{printf "%s=%s ", $$2, $$1}')" || true
	@for d in $(STATUS_DIRS); do \
	    if test -d "$$d"; then \
	        n=$$(find "$$d" -type f | wc -l); sz=$$(du -sh "$$d" 2>/dev/null | cut -f1); \
	        t=$$(find "$$d" -type f -printf '%T@\n' | sort -n | tail -1); \
	        printf 'dir:       %-28s %s file(s), %s, newest change %s\n' "$$d" "$$n" "$$sz" \
	            "$$(test -n "$$t" && date -d @$${t%.*} '+%F %T %Z' || echo -)"; \
	    else \
	        printf 'dir:       %-28s missing\n' "$$d"; \
	    fi; \
	done
