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
  cmd/list-containers/   setuid-root binary — container name/IP discovery
  cmd/vps-proxy/         TLS SNI passthrough proxy (port 443)
  cmd/vps-proxy-http/    HTTP reverse proxy (port 80)
  mapping/               hostname → container-name mapping, domain list
  routes/                live routing table (refreshed every 5 s)
  sni/                   TLS ClientHello SNI parser
container/               same image as the subdomain edition
host/
  bind/zone.tmpl                  host-managed part of every zone
  bind/named.conf.local.tmpl      per-zone statement (installed in zones.d/)
  opendkim/opendkim.conf.tmpl     KeyTable/SigningTable (one key per domain)
  systemd/vps-proxy*.service      proxy units (-domains-file /etc/vps-mcp/domains)
  nftables/vps-mcp.nft.tmpl       INPUT allow-list + OUTPUT restriction
scripts/
  zone.sh                register / update / remove a zone
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
