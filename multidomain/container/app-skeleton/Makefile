# Deploy this repository onto the container it is checked out in:
#     make -C /srv/app install
#
# The same commit is installed on development, staging and production (the
# host sends it with `make <fqdn>.to-stg` / `make <fqdn>.to-prod`), so this
# Makefile must work on a container that has only what the image provides plus
# what this repository installs. Keep it idempotent and stop on the first error.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

# files/ mirrors the filesystem: files/etc/nginx/app.d/x.conf is installed as
# /etc/nginx/app.d/x.conf. Directories listed here are mirrored exactly (a file
# deleted from the repository is deleted there too); everything else under
# files/ is copied over without deleting anything.
MIRROR_DIRS := etc/nginx/app.d

# Per-environment files placed by hand on each server and never committed
# (passwords, API keys, ...). install stops if one is missing.
REQUIRED_LOCAL :=

ROLE := $(shell sed -n 's/^ROLE=//p' /etc/vps-mcp-env 2>/dev/null)

RSYNC := rsync -rlt --checksum --exclude=.gitkeep

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
