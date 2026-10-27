# vps-mcp — multidomain edition

Podman-based VPS environment that hosts **several domains on one server**
(e.g. `test.ksy.jp` and `pa-i.jp` side by side). Each container serves one
full hostname and is named after it (`test.ksy.jp-web`, `pa-i.jp-web`); it runs
Rocky Linux with an MCP server that lets Claude.ai manage files and run shell
commands. One GitHub OAuth App and one login broker serve every domain.

Compared with [`subdomain/`](../subdomain/README.md) (one base domain,
containers named after the subdomain label), choose **one edition per server**:
both bind ports 53/80/443/25 on the host.

## Architecture

```
Internet
  │
  ├─ :53   BIND9 (one zone per registered domain: @ and * → server IP)
  │
  ├─ :443  vps-proxy (SNI passthrough, PROXY protocol v1)
  │            └─ container :443  nginx (TLS termination)
  │                                  └─ 127.0.0.1:3000  Node.js MCP server
  │
  └─ :80   vps-proxy-http (HTTP reverse proxy)
               └─ container :80  nginx
```

- **BIND9** is the primary authoritative server for every registered domain (`make <domain>.dnsdone`).
- **vps-proxy** reads the TLS ClientHello SNI and maps `test.ksy.jp` → container `test.ksy.jp-web` when `ksy.jp` is listed in `/etc/vps-mcp/domains` (the domain itself or one label below it). Unknown names under a domain fall back to the domain's apex container (`ksy.jp-web`), if any. It TCP-proxies without decryption and injects PROXY protocol v1 so nginx sees the real client IP.
- **vps-proxy-http** does the same with the HTTP `Host` header.
- Both proxies re-read `/etc/vps-mcp/domains` when it changes — no restart after adding a domain.
- **list-containers** (setuid-root) queries the Podman socket to build the container→IP routing table used by both proxies.
- Each container runs systemd, nginx, Postfix (nullclient), and the MCP server. Host-side opendkim signs each domain's mail with that domain's own key.

## Directory layout

```
proxy/
  cmd/list-containers/   container name/IP discovery (run as root by the proxy units)
  cmd/vps-proxy/         TLS SNI passthrough proxy (port 443)
  cmd/vps-proxy-http/    HTTP reverse proxy (port 80)
  mapping/               hostname → container-name mapping, domain list
  routes/                live routing table (refreshed every 5 s)
  sni/                   TLS ClientHello SNI parser
container/
  nginx/vps-mcp.conf     server blocks; includes mcp.d/ (MCP) and app.d/ (one file per app)
  nginx/mcp.conf         MCP locations → /etc/nginx/mcp.d/mcp.conf
  nginx/app-default.conf default "location /" → /etc/nginx/app.d/default.conf
  app-skeleton/          /srv/app of a create3 dev container (CLAUDE.md, Makefile, files/)
  systemd/vps-mcp-recv.sh  receives a git bundle into /srv/app (dev2stg / stg2prod)
host/
  three/                          create3 host side: staging view hook, mail copies, name list
  bind/zone.tmpl                  host-managed part of every zone
  bind/named.conf.local.tmpl      per-zone statement (installed in zones.d/)
  opendkim/opendkim.conf.tmpl     KeyTable/SigningTable (one key per domain)
  systemd/vps-proxy*.service      proxy units (-domains-file /etc/vps-mcp/domains)
  nftables/vps-mcp.nft.tmpl       INPUT allow-list + OUTPUT restriction
scripts/
  zone.sh                register / update / remove a zone
  names3.sh              production → staging / dev hostnames of a create3 set
example.com.dns          sample records file — copy to <domain>.dns
Makefile
```

## Prerequisites

- Podman (rootful)
- Go 1.21+
- `make`

### Server sizing

Each container runs systemd, nginx, Postfix and a Node.js MCP server — roughly
**110–130 MB of RAM per container** at idle, plus 200–300 MB for the host
(kernel, podman, BIND, opendkim, postfix). Periodic `dnf` runs inside the
containers spike by several hundred MB each. Rough guide: 1 GB / 1 core for up
to ~3 containers, **2 GB / 2–3 cores for up to ~8**, 4 GB+ beyond that.

An undersized host swap-thrashes when dnf timers fire (CPU and disk I/O pinned
at 100%, SSH unresponsive). Setup mitigates this — zram swap, persistent
journal, `dnf-makecache.timer` disabled on the host and in the image, and
container `dnf-automatic-install` firings spread with `RandomizedDelaySec` —
but mitigation is no substitute for enough RAM.

A [three-container set](#three-container-sets-production--staging--development)
needs less than three standalone containers: staging and production run no
Node.js. Measured on a 449 MB host with zram: about 60 MB resident for the dev
container and 12 MB each for staging and production at idle, before the
application's own processes. Two simultaneous container `dnf` runs peaked at
about 320 MB of swap, mostly absorbed by zram. Plan on 1 GB or more per set.

## Installation

Run once as root on the host, substituting the server's public IP:

```sh
make 203.0.113.1.setupdone
```

This:
1. Applies all pending OS updates (`dnf upgrade` / `apt upgrade`) so a fresh VPS starts current
2. Writes `/etc/vps-mcp/host.env` (`IP`, `BIND_ZONE_DIR`, `BIND_CONF`). The host name is left alone — do **not** set it to one of the hosted domains, or the relay postfix would deliver that domain's mail locally.
3. Installs BIND9 (authoritative only, no zones yet), opendkim (empty key tables) and a relay-only `postfix` so containers can send mail
4. Builds the container image (`vps-mcp:latest`) and the Go proxy binaries (`list-containers`, `vps-proxy`, `vps-proxy-http` in `/usr/local/sbin`)
5. Installs the proxy socket/service units (`vps-proxy{80,443}`) and nftables rules, then enables + starts them
6. Enables unattended security updates (`dnf-automatic`) and a weekly reboot (`vps-mcp-reboot.timer`, Sunday ~04:00); `podman-restart.service` brings `--restart=always` containers back up after each reboot
7. Hardens the host against memory pressure: enables zram swap and a persistent journal, and disables the host's `dnf-makecache.timer` (see [Server sizing](#server-sizing))

> **Long-lived containers**: containers run for weeks, so they receive Rocky Linux security updates automatically via `dnf-automatic-install.timer`. They are not rebooted individually — the host's weekly reboot plus `--restart=always` refreshes them.

### Moving DNS first

`make 203.0.113.1.dnssetupdone` installs only BIND (setupdone runs it too and
keeps its zones). Run it alone on a host whose web server should stay as it
is for now, register zones with `make <domain>.dnsdone`, and switch the domain
at the registrar's DNS to "secondary of this host". Open port 53 (tcp/udp) if
firewalld is still running. Run `make <IP>.setupdone` later to add the rest.

## Registering a domain

Each domain has a records file `<domain>.dns` next to the Makefile (git-ignored;
`example.com.dns` is the committed sample):

```sh
cp example.com.dns ksy.jp.dns
vi ksy.jp.dns            # MX, TXT, CNAME, ... (names relative to the domain)
make ksy.jp.dnsdone      # first run registers, later runs update
```

The zone is built from two parts:

| Part | Source | Contents |
|---|---|---|
| Host-managed | `host/bind/zone.tmpl` + DKIM key | SOA, NS, `ns1` A, `mail._domainkey` |
| Host defaults | `host/bind/zone.tmpl` | `@` / `*` A (this server), `@` / `*` SPF, `_dmarc` (`p=none`) |
| Operator-managed | `<domain>.dns` | everything else (MX, verification TXT, CNAME, ...) |

A host default is dropped when `<domain>.dns` has the same kind of record:
`@ IN A` (e.g. the apex stays on another server or GitHub Pages), `* IN A`,
a `v=spf1` TXT at `@` or `*` (keep an existing SPF), or a `v=DMARC1` TXT at
`_dmarc`. Other TXT records (site verification etc.) never replace anything.

`make <domain>.dnsdone` re-runs only when `<domain>.dns` changed. It rejects SOA/NS
records, `$` directives, owner-less lines, anything under `mail._domainkey`, and
A/AAAA/CNAME records on a name a container serves; then it bumps the serial and
runs `named-checkzone`. On any error the live zone is left untouched. To delete
a record, remove its line and re-run. A copy of the records file is kept in
`/etc/vps-mcp/zones/` in case the checkout is lost.

The first run also creates the DKIM key, the opendkim table entries, the zone
statement (`zones.d/<domain>.conf`, included from `named.conf.local`), and adds
the domain to `/etc/vps-mcp/domains` so the proxies start routing it.

```sh
make domains             # registered domains and zone serials
make ksy.jp.undns        # remove the zone (refused while containers use it;
                         #   the DKIM key is kept for re-registration)
```

> **DNS delegation**: at each domain's registrar, point the NS records to this
> server and register the zone with the secondary DNS (`ns1/ns2.dns.ne.jp`,
> see `host/bind/named.conf.local.tmpl`). Every zone uses `ns1.<domain>` as its
> primary NS by default, which needs a glue record per domain. To share one, add
> `NS1=ns1.ksy.jp` to `/etc/vps-mcp/host.env` before registering the others.

## GitHub login broker (one-time setup)

Authentication uses real GitHub OAuth. Register one GitHub OAuth App and run a
single broker container that serves logins for **every domain on the host**.
Its hostname may be under any registered domain; `oauth.ksy.jp` is used below.

1. Create a GitHub OAuth App (Settings → Developer settings → OAuth Apps → New):
   - **Homepage URL**: `https://oauth.ksy.jp`
   - **Authorization callback URL**: `https://oauth.ksy.jp/mcp/callback`
2. Fill in `/etc/vps-mcp/oauth.env` (host setup already created it as a mode-600
   template; edit in the real values):
   ```
   GITHUB_CLIENT_ID=...
   GITHUB_CLIENT_SECRET=...
   ```
3. Create the broker container (it is the only one holding the GitHub secret):
   ```sh
   make oauth.ksy.jp__admin@gmail.com.done
   ```
   Its hostname is saved as `OAUTH_HOST` in `host.env`; a second broker is refused.

Every other container, on any domain, learns only `OAUTH_BASE=https://oauth.ksy.jp`.

## Creating a VPS container

```sh
make test.ksy.jp__alice@gmail.com.done    # container test.ksy.jp-web
make pa-i.jp__bob@gmail.com.done          # domain apex: container pa-i.jp-web
```

The hostname must be a registered domain or one label below it, and the broker
must exist first. This:
1. Runs `podman run` with `SUBDOMAIN` and `MAIL_DOMAIN` set to the hostname, `NOTIFY_EMAIL`, and `OAUTH_BASE=https://$OAUTH_HOST`
2. Waits for the proxy to route the HTTP-01 ACME challenge path to the new container
3. Runs `podman exec <hostname>-web /usr/local/bin/vps-mcp-init.sh`, which:
   - Writes `/etc/vps-mcp-env`
   - Creates `/etc/mcp-server` (holds the issued token hash at login time)
   - Configures Postfix `myhostname`/`myorigin` to the hostname
   - Substitutes `server_name` in the nginx config and reloads nginx
   - Obtains a Let's Encrypt certificate via `certbot certonly --webroot`
   - Switches nginx to the live certificate
   - Runs `systemctl enable --now mcp-server`
   - Sends a creation notification email to `NOTIFY_EMAIL` from `noreply@<hostname>`
4. Creates `test.ksy.jp__alice@gmail.com.done` to record completion

Access is granted by **GitHub login**: a user only obtains a Bearer token if they
log in with a GitHub account whose verified primary email matches `NOTIFY_EMAIL`.

List containers, grouped by domain:

```sh
make list
```

Delete a container (manual):

```sh
podman stop test.ksy.jp-web && podman rm test.ksy.jp-web
rm -f test.ksy.jp__alice@gmail.com.done
```

## Three-container sets (production / staging / development)

For an application whose production server holds customer data, Claude should
work only on a development copy. `create3` makes three containers from the same
image:

| Hostname | Role | MCP | Updated by |
|---|---|---|---|
| `shop.ksy.jp` | production | no | a person on the host: `make shop.ksy.jp.stg2prod` |
| `shop-stg.ksy.jp` | staging (checks that the Makefile works) | no | a person on the host: `make shop.ksy.jp.dev2stg` |
| `shop-dev.ksy.jp` | development | yes | Claude, through the MCP connector |

For a domain apex (`ksy.jp`) the others are `stg.ksy.jp` and `dev.ksy.jp`.
Do not use `-stg` / `-dev` labels (or `stg` / `dev` under an apex) for
anything else: the mail copy and the staging view below select containers by
these names.

```sh
make install-services                   # once per host (also after a git pull)
make shop.ksy.jp__alice@gmail.com.create3
```

`create3` creates the three containers, runs the usual first-boot init on each
(certificate, Postfix; MCP only on dev), puts a skeleton repository in the dev
container's `/srv/app` (`CLAUDE.md`, `Makefile`, `files/`) and sends it through
staging to production, so all three share one git history from the start.
Register only the dev container as a connector (`https://shop-dev.ksy.jp/mcp/sse`).

### Workflow

1. Claude edits `/srv/app` in the dev container, tries it with `make install`,
   and commits. `/srv/app/CLAUDE.md` explains the conventions to Claude.
2. `make shop.ksy.jp.dev2stg` sends dev's committed HEAD to staging (refused if
   dev has uncommitted changes, or if staging's `/srv/app` was edited by hand)
   and runs `make -C /srv/app install` there. On failure, `install` prints
   diagnostics; hand them to Claude.
3. `make shop.ksy.jp.stg2prod` shows the commits and the **full diff**
   production will receive, asks for confirmation, sends **staging's** HEAD
   (so production gets exactly what staging ran, even if dev has moved on),
   fast-forward only, and runs `make install` there.
4. `make shop.ksy.jp.list3` shows the three containers and their HEADs.

After each transfer the dev repository records `stg/main` and
`prod/main` (remote-tracking refs), so Claude can see what each server
runs — e.g. branch a hotfix from `prod/main`. Staging follows whatever is
sent, so such a hotfix can go through staging to production.

Claude's trial and error never reaches production: production and staging
have no MCP server (`mcp.d/` is empty, `/mcp/` does not exist), and the only
way anything reaches them is a person running `make` on the host.

### What the dev container sees of staging

- **`/mnt/stg`** — staging's whole filesystem, read-only and live. An OCI
  hook (`/usr/share/containers/oci/hooks.d/vps-mcp-stgview-*.json`) binds the
  staging rootfs with a single `mount --bind -o ro` on every staging start and
  removes it on stop; the dev container mounts it `ro,rslave`. Container root
  cannot remount it read-write (no `CAP_SYS_ADMIN`; the read-only flag is
  locked even inside a user namespace). Hook actions are logged:
  `journalctl -t vps-mcp-stgview`.
- **`/srv/stg-mail/`** — a copy of every message staging sends (one `.eml` per
  message, kept 14 days). The message itself is delivered normally. The mail
  policy adds `BCC stgcapture+<staging>@localhost` for staging containers only,
  before queueing, so no copy of production mail is ever written on the host.

### Host pieces (`make install-services`)

| File | Purpose |
|---|---|
| `vps-mcp-containers.service` | `/run/vps-mcp/containers`: name/IP list for the mail policy |
| `vps-mcp-view.service` | at boot, before `podman-restart.service`: shared view root and per-staging mount points |
| `hooks.d/vps-mcp-stgview-{poststart,poststop}.json` + `vps-mcp-stgview-hook.sh` | staging view (see above) |
| `vps-mcp-mailquota.sh` | daily quota, plus the staging BCC |
| `/etc/aliases` `stgcapture`, `recipient_delimiter = +` | staging copies → `/var/spool/vps-mcp-stgmail/` |
| `vps-mcp-stgmail.path` / `.service` | hand each copy to the dev container |
| `vps-mcp-stgmail-retry.timer` | retry copies held while the dev container was down |

`make mcpupdate` updates the dev container of a set and skips its staging and
production; `make shop.ksy.jp.mcpupdate` updates `shop-dev.ksy.jp`.

## nginx layout: `mcp.d/` and `app.d/`

Containers created from the current image include, inside the HTTPS server
block of `/etc/nginx/conf.d/vps-mcp.conf`:

- `/etc/nginx/mcp.d/*.conf` — the MCP server's locations (empty on staging and
  production of a set)
- `/etc/nginx/app.d/*.conf` — **one file per application** (location blocks)

so adding an application never rewrites another application's — or the MCP
server's — configuration from a stale copy. The tool descriptions tell Claude
to use `app.d/<application>.conf` when this layout is present.

Every HTTPS server block includes `/etc/nginx/listen443.conf` and
`/etc/nginx/ssl-cert.conf` instead of its own `listen` / `ssl_certificate`
lines, and the port-80 server includes `/etc/nginx/http80.d/*.conf`; an extra
server block for another hostname (in `conf.d/`) must do the same. Forward mode
and `getcert` switch every server block by rewriting these files.

### Migrating an existing container's nginx configuration

Containers created before this layout keep every location in `vps-mcp.conf`
(`make check` reports it as DIFFER plus `NOTE … old nginx layout`). Migrate
through the container's own connector, by asking Claude:

> In this container, split /etc/nginx/conf.d/vps-mcp.conf into the mcp.d/ and
> app.d/ layout of the vps-mcp repository (multidomain/container/nginx/):
> 1. Copy vps-mcp.conf to /root/vps-mcp.conf.bak.
> 2. Move the MCP locations (`= /.well-known/oauth-authorization-server` and
>    every `/mcp/...` location) unchanged into /etc/nginx/mcp.d/mcp.conf.
> 3. Move every other location of the HTTPS server block, grouped per
>    application, into /etc/nginx/app.d/<application>.conf (the plain
>    `location /` serving /var/www/html goes to app.d/default.conf).
> 4. In vps-mcp.conf, replace the moved locations with
>    `include /etc/nginx/mcp.d/*.conf;` and `include /etc/nginx/app.d/*.conf;`,
>    and add the "DO NOT EDIT THIS FILE" header comment of the repository copy.
>    Leave the server blocks, certificates and redirects as they are.
> 5. Run `nginx -t`; if it fails, restore the backup. Then use the
>    nginx_reload tool (not systemctl) and check that the site and
>    /.well-known/oauth-authorization-server still answer.

Then run `make <name>.mcpupdate` so the tool descriptions mention `app.d/`.

## Moving a site from an old server (forward mode)

A container created with the old server's IP in front of its name starts in
**forward mode**, so a site can move here without going down:

```sh
make 153.126.216.5__pa-i.org__alice@gmail.com.done      # one container (MCP inside)
make 153.126.216.5__pa-i.org__alice@gmail.com.create3   # or a set: only production forwards
```

| Port | Forward mode | After `unforward` |
|---|---|---|
| 443 | passed through **still encrypted** to `OLD:443` (nginx stream; the old server keeps serving with its own certificate) | served here; `app.d/forward.conf` proxies whatever is not ported yet to `https://OLD` |
| 80 | ACME challenges answered here (falling back to the old server, so its renewals keep working); the rest proxied to `OLD:80` | ACME here, the rest redirected to HTTPS |

The usual sequence:

1. Register the domain here (`make <domain>.dnsdone`) with the same records,
   then create the container(s) as above. The certificate request at creation
   fails while the name still points at the old server; that is expected.
2. Point the domain's DNS at this host (e.g. switch the Sakura zone to a
   secondary of this host). Visitors keep reaching the old site through the
   passthrough.
3. `make pa-i.org.getcert` — one Let's Encrypt certificate for the hostname and,
   on a production or standalone container, every name in
   `/etc/vps-mcp/cert-names` (e.g. `www` and redirect-only names that reach the
   apex container). Re-run to add a name or after a failure.
4. `make pa-i.org.unforward` (refused until step 3 succeeded). This container
   now serves 443: the MCP server and everything ported answer here, the rest
   still goes to the old server through `app.d/forward.conf`.
5. Port the remaining parts; narrow `forward.conf`, and delete it when nothing
   is left on the old server. In a create3 set these files live in the dev
   repository (`files/`), seeded at creation, and reach production with
   `dev2stg` / `stg2prod` like any other change.

`make pa-i.org.forward` (optionally `OLD=<IP>`) returns to forward mode and
`make pa-i.org.mode` shows the mode and certificate. Everything runs inside the
container (`/usr/local/bin/vps-mcp-mode.sh`); the host only runs `podman exec`
— nothing on the host proxies traffic. The old server sees every request
coming from this host's address (no PROXY header is passed on). In forward
mode the container's own MCP server is unreachable (443 belongs to the old
site); in a create3 set the MCP server is on the dev container and stays usable.

## MCP connector setup

After the container is created:

1. The creation notification email arrives at `NOTIFY_EMAIL` (confirms the mail path works).
2. Add the MCP connector in Claude.ai with the SSE URL:
   ```
   https://test.ksy.jp/mcp/sse
   ```
3. Claude.ai opens the authorization page, which redirects to GitHub. Log in with
   the GitHub account whose verified primary email is `NOTIFY_EMAIL`.
4. On a successful email match, a token-issuance notification email is sent from
   `noreply@test.ksy.jp` to `NOTIFY_EMAIL`.
5. Claude.ai connects and the tools become available: `exec_command`, `read_file`, `write_file`, `nginx_reload` (use the latter instead of reloading nginx through `exec_command`, which would interrupt the SSE connection), and `deploy_setup` (see below).

The login flow is PKCE-protected (S256): the GitHub authorization code is consumed
immediately at the broker and never reaches Claude.ai; only a SHA-256 hash of the
issued Bearer token is retained on disk for subsequent authentication.

Each tool description carries `This connector is bound to the VPS <subdomain>.`
so Claude can tell which host a connector targets (one container serves exactly
one hostname) and avoid acting on the wrong VPS.

## Deploy from GitHub (Actions OIDC → PUT)

`deploy_setup` returns a ready-to-commit `.github/workflows/deploy.yml` that
uploads a repository's files to the container over HTTPS using a GitHub Actions
**OIDC token** — no secret is stored. Files are PUT to
`https://<subdomain>/mcp/messages/deploy/<dest>/<path>` (under the already-proxied
`/mcp/messages` location, so no extra nginx config) and land under
`DEPLOY_BASE_DIR` (default `/srv/deploy`; this is a landing directory, **not**
the web root — publish it yourself if desired).

The deploy endpoint accepts OIDC tokens whose `aud` is this host and whose
`repository_owner_id` matches the GitHub account that logged in here — so any
repo under that account can deploy, from any branch or event. The owner id is
learned from the broker's `/mcp/resolve` response and bound at login
(`/etc/mcp-server/deploy_owner`). Until a login binds it, `deploy_setup` still
returns the workflow but prints a warning. The endpoint is **not** offered on the
oauth broker container.

For replay protection each token's `jti` is accepted **once**, so one token covers
exactly one PUT — a workflow that mints a single token and loops over several
files gets 401 from the second file on. The generated workflow therefore mints a
fresh token inside the upload loop, one per file.

## Updating the MCP app

The MCP app (`index.mjs` + its `node_modules`) is baked into the image and copied
into each container. A rollout has two independent scopes — run **both**:

```
make image               # rebuild the image → only containers created afterwards
make mcpupdate           # patch every running container in place (stop + cp + npm install/update + start,
                         #   plus any missing diagnostic tool: ss, ps, lsof, sqlite3, jq)
make test.ksy.jp.mcpupdate  # patch a single container (stem → <stem>-web)
```

`mcpupdate` patches in place (not recreate) because each container holds
persistent state in its writable layer — the Bearer token hash, the deploy-owner
binding, certbot certificates, and `/var/www/html` — that a recreate would
discard. When upgrading the broker and content containers together, update the
**oauth container first** so `/mcp/resolve` returns `owner_id` before the others
try to bind it.

## Security notes

- The SNI proxy never decrypts TLS traffic.
- The PROXY protocol header is generated from `conn.RemoteAddr()` only; client-supplied PROXY headers are rejected by the SNI check (`0x16` byte).
- `set_real_ip_from` is scoped to the single gateway IP (`10.89.0.1`), not the whole subnet.
- Access requires a GitHub login whose verified primary email matches `NOTIFY_EMAIL`; the email match is enforced per-container, so the allow-list is never centralized.
- The PKCE verifier is the only key to retrieving the resolved email from the broker (`/mcp/resolve` is self-authenticating: it looks the email up by `SHA256(verifier)`), so it needs no shared secret or IP restriction.
- The GitHub authorization code is exchanged immediately at the broker and never handed to Claude.ai; the broker holds the GitHub `client_secret` and is the only container that does.
- The `/mcp/token` endpoint keeps the Anthropic IP allow-list (`160.79.104.0/21`) as defense in depth; the real gate is PKCE plus the GitHub email match.
- Only a SHA-256 hash of the issued Bearer token is retained on disk.
- The MCP server listens on `127.0.0.1:3000` only.
- `vps-mcp.nft` runs a default-drop INPUT filter that exposes only SSH (22), HTTP/HTTPS (80/443), and DNS (53) publicly; SMTP (25) is reachable from the container subnet only.
- Outbound mail is limited per container on the host relay: 5 messages / 20 recipients per minute (Postfix anvil; excess is deferred with 4xx and retried from the container's queue) and 200 messages per day (`host/postfix/vps-mcp-mailquota.sh` policy service; excess is rejected with 5xx). Direct outbound SMTP (25) from containers is blocked in the nftables forward chain, so the relay cannot be bypassed. Containers run with `--cap-drop NET_RAW,NET_ADMIN`, so they cannot spoof another source IP to evade the per-IP limits. Run `make install-services` to apply this to an already-installed host.
- `vps-mcp.nft` also blocks new outbound connections from non-root host users; established/related traffic is always allowed.
- Optional SSH hardening is available via `make sshsec.done` (not run by setup): it disables host SSH password authentication (`host/ssh/00-vps-mcp-hardening.conf` — access is key-based, and since containers grant participants root and can reach the host's `:22`, this removes brute-force exposure of host accounts) and installs `fail2ban` with the nftables banaction (`host/fail2ban/jail.d/00-vps-mcp.conf`).

## License

MIT — see [LICENSE](LICENSE).

---

*This code and documentation were created with [Claude](https://claude.ai/) (Sonnet 4.6 and Opus 4.8).*
