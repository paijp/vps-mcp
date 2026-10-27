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
# /opt/env.d/<app>/env.py, which install never writes: a person copies the
# template there once on staging and once on production (on the development
# container install copies it when missing).
APPS := $(notdir $(patsubst %/,%,$(wildcard files/opt/app.d/*/)))
ENV_APPS := $(foreach a,$(APPS),$(if $(wildcard files/opt/app.d/$(a)/env.py.sample),$(a)))

# Other per-environment files placed by hand on each server and never
# committed (passwords, API keys, ...). install stops if one is missing.
REQUIRED_LOCAL :=

ROLE := $(shell sed -n 's/^ROLE=//p' /etc/vps-mcp-env 2>/dev/null)

RSYNC := rsync -rlt --omit-dir-times --checksum --exclude=.gitkeep

.PHONY: install install-inner check files reload getlog diff

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
ifeq ($(ROLE),dev)
	@for a in $(ENV_APPS); do \
	    test -e /opt/env.d/$$a/env.py || { install -D -m 644 files/opt/app.d/$$a/env.py.sample /opt/env.d/$$a/env.py; \
	        echo "dev: created /opt/env.d/$$a/env.py from env.py.sample"; }; \
	done
endif
	@for a in $(ENV_APPS); do \
	    f=/opt/env.d/$$a/env.py; \
	    test -e "$$f" || { echo "missing $$f (place it by hand on this server):"; \
	        echo "    mkdir -p /opt/env.d/$$a && cp /srv/app/files/opt/app.d/$$a/env.py.sample $$f"; exit 1; }; \
	    for v in $$(sed -n 's/^\([A-Z_][A-Z0-9_]*\) *=.*/\1/p' files/opt/app.d/$$a/env.py.sample); do \
	        grep -q "^$$v *=" "$$f" || echo "warning: $$f has no $$v (see env.py.sample)"; \
	    done; \
	done
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
