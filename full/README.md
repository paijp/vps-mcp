# vps-mcp — full edition (single-host, GitHub login)

A single-host Claude.ai MCP server that gives Claude root-level control of one VPS.
Unlike the [`startupscript/`](../startupscript/) edition (which authenticates with a
pre-shared `client_secret`), this edition uses **real GitHub OAuth login**: a Bearer token
is issued only after a browser GitHub login whose verified primary email matches the
owner's `NOTIFY_EMAIL`.

Because this is a single host (one VPS, one owner), the authorization-server role seen by
Claude.ai and the GitHub-login broker role live in the **same process** — there is no
separate broker container as in the multi-tenant [`subdomain/`](../subdomain/README.md)
edition. The GitHub OAuth App's single callback is this host's `/mcp/callback`.

## Security

This server provides **root-level shell execution (`exec_command`) via MCP** by design.

- **Token leakage = root access leakage.**
- **Do not place SSH keys** on this server to reach other hosts.
- VPS operations via Claude are **at your own risk** (irreversible actions are possible).
- If you receive an unexpected token-issuance email, **discard the VPS and rebuild**.

The Bearer token is minted dynamically at login and only its sha256 hash is stored
(`/etc/mcp-server/hash`). Email notification fires **only** at token issuance.

### Fixed token (opt-in)

By default each successful login mints a fresh random token and overwrites the hash, so the
previous token is rotated out and only the hash is ever stored. If you instead place a
root-only `mode 600` file at `/etc/mcp-server/token` (≥32 chars), `/mcp/token` reuses its
contents on every issuance, so the **same Bearer can be issued repeatedly** — useful for
sharing one token across accounts or for stable reconnection.

The GitHub-login gate still guards issuance (a caller must pass GitHub login + `NOTIFY_EMAIL`
match to receive it). The trade-offs: the plaintext token then lives **at rest** (weakening
the hash-only property), and login **no longer rotates** it. To revoke, delete both
`/etc/mcp-server/token` and `/etc/mcp-server/hash`.

## Prerequisites

- A VPS (RockyLinux / Debian-family) with root, ≥512MB RAM.
- A domain whose A record (and `ns1` glue, if this host is the nameserver) points at the VPS.
- A **GitHub OAuth App** (created once — see below).

## Setup

Run as root from this directory.

### 1. Host setup

```
make 203.0.113.1__example.com__admin@example.com.setupdone
```

Stem format is `IP__DOMAIN__EMAIL`. This builds: swapfile, BIND wildcard DNS, nginx,
Node.js 22, the MCP server, certbot (waits for DNS propagation), firewall, OpenDKIM/Postfix,
and auto-updates. It also writes an `/etc/vps-mcp/oauth.env` template (mode 600). The MCP
server starts, but GitHub login will not work until credentials are filled in.

No email is sent at this stage.

### 2. Create a GitHub OAuth App

On GitHub → Settings → Developer settings → **OAuth Apps** → New OAuth App:

- **Homepage URL:** `https://example.com`
- **Authorization callback URL:** `https://example.com/mcp/callback`

Copy the **Client ID** and generate a **Client Secret**.

### 3. Apply credentials

Edit `/etc/vps-mcp/oauth.env`:

```
GITHUB_CLIENT_ID=<client id>
GITHUB_CLIENT_SECRET=<client secret>
```

Then:

```
make oauth.done
```

This validates the values are present, restarts `mcp-server`, and records completion.
Re-running after any future edit of `oauth.env` re-applies automatically (the target
depends on the file's timestamp).

### 4. Register the Claude.ai connector

```
Customize → Connectors → Add → Custom Connector
URL: https://example.com/mcp/sse
```

On connect, the browser is sent through GitHub login. A Bearer is issued **only** if the
verified primary email matches `NOTIFY_EMAIL` (set to the owner's email during setup). A
single notification email is sent at that moment.

### Updating an already-set-up host

After pulling a newer version of this repo onto the host:

```
make mcpupdate
```

This stops `mcp-server`, reinstalls `/opt/mcp` (`index.mjs`, `package.json` + deps), the
systemd unit and `/srv/deploy`, then restarts it — without re-running the full host setup.
(The service is stopped first so a crash mid-update can't auto-restart on half-written
files.) The same target is used internally by `make …setupdone`, so initial install and
update share one code path. It does **not** touch the nginx config (certbot rewrites the TLS
lines there); if `full/nginx/vps-mcp.conf` changed, merge it into the live conf manually.

## MCP tools

| Tool | Function |
|---|---|
| `exec_command` | Run a shell command on the VPS (root), returns stdout/stderr |
| `read_file` | Read a file from the VPS filesystem |
| `write_file` | Write content to a file (large files supported; body limit raised to 25MB) |
| `nginx_reload` | Validate and reload nginx (deferred so the SSE result is flushed first) |
| `deploy_setup` | Generate a ready-to-commit GitHub Actions workflow that deploys files to this host via OIDC (see below) |

## Endpoints

| Path | Purpose |
|---|---|
| `/.well-known/oauth-authorization-server` | OAuth discovery (PKCE S256, public client) |
| `/mcp/register` | Dynamic client registration (RFC 7591) |
| `/mcp/authorize` | Validates redirect_uri is claude.ai + PKCE S256, redirects to GitHub |
| `/mcp/callback` | Exchanges the GitHub code, binds verified email to the PKCE challenge |
| `/mcp/token` | Issues a Bearer iff resolved email matches `NOTIFY_EMAIL` |
| `/mcp/sse`, `/mcp/messages` | MCP SSE transport (Bearer auth) |
| `PUT /deploy/<path>` | Receive a file from GitHub Actions, authenticated by a GitHub OIDC JWT |

## Deploy from GitHub (Actions OIDC → PUT)

Push files to this host straight from a GitHub repository — no stored secret. A GitHub
Actions workflow mints a short-lived **OIDC token** at runtime; the server verifies it
(signature via GitHub's JWKS, plus `iss` / `aud` / `exp` / single-use `jti`) and writes the
body under `DEPLOY_BASE_DIR`. Because byte content travels host-to-host (not through the
model), binary and large files work without truncation.

**Owner binding is automatic:** at GitHub login the server records your numeric account id
(`/etc/mcp-server/deploy_owner`). `/deploy` then accepts OIDC tokens whose
`repository_owner_id` matches — i.e. any repo/branch/event under your account. No other
account can deploy. (To restrict by branch/event, add a claim check; the default is
permissive by design.)

Setup: complete a GitHub login through the connector, then call the **`deploy_setup`** MCP
tool ("set up GitHub deploy"). It returns a ready-to-commit `.github/workflows/deploy.yml`
pre-filled with this host. Commit it to a repo you own and pushes will deploy to
`https://<host>/deploy/<dest>/…`.

**Workflow chaining caveat:** the default trigger is `push`, which fires only on a *human*
push. A push made by another workflow using the default `GITHUB_TOKEN` will **not** trigger
it (GitHub blocks workflow chaining). If the files are produced by a build workflow, either
add the deploy steps to that workflow, or call `deploy_setup` with `build_workflow` set to
the build's name to get a `workflow_run`-triggered variant instead.

## Environment

From `/etc/vps-mcp/host.env` and `/etc/vps-mcp/oauth.env`:

| Var | Meaning |
|---|---|
| `SUBDOMAIN` | full hostname, e.g. `example.com` |
| `NOTIFY_EMAIL` | the owner's email; only this GitHub account is allowed |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | GitHub OAuth App credentials |
| `DEPLOY_BASE_DIR` | where `/deploy` writes files (default `/srv/deploy`) |
| `DEPLOY_AUDIENCE` | required OIDC `aud` (default: `SUBDOMAIN`) |
