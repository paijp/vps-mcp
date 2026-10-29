# Design notes (multidomain edition)

Why things are the way they are: the decisions behind the current design, the
alternatives that were considered, and the problems that led to them. The
README says how to use it; this file says why, so a later change does not
undo a decision without knowing what it was for.

## Three-container sets (production / staging / development)

- **Claude works only in the dev container.** Production and staging run no
  MCP server and cannot be reached from dev. Claude's trial and error never
  touches production data; a person moves a commit forward with
  `make <fqdn>.dev2stg` / `.stg2prod` on the host.
- **One git history, sent as bundles.** The dev repository (`/srv/app`) is the
  only place commits are made. The host pipes `git bundle` through
  `podman exec -i`, so no container needs network access to another, and no
  credential is stored anywhere. Staging follows whatever is sent (it may go
  back for a hotfix); production only fast-forwards, so it always runs a
  commit staging ran.
- **`make install` is the only way files reach the system**, on all three
  containers alike, and it is idempotent. `stg2prod` therefore re-runs it when
  production already has staging's HEAD (an install that stopped on a missing
  hand-placed file is simply retried).
- **What `install` mirrors.** Only directories the repository owns entirely
  are mirrored (deleted files disappear on the servers): `/etc/nginx/app.d/`
  and `/opt/app.d/`. Shared directories (`conf.d/`, `/etc/systemd/system/`,
  `/etc/vps-mcp/`) hold files of the image or the OS too, so they are only
  copied into, never cleaned.
- **Secrets are placed by hand, once per server.** An application ships
  `env.py.sample`; the real `/opt/env.d/<app>/env.py` is never written by
  `install` (on dev it is copied from the sample). `install` stops with the
  exact copy command when it is missing, warns when the sample has a variable
  the real file lacks, and refuses an `env.py` inside the repository.
- **`stg2prod` shows commits and `--stat`, not the full diff** (`DIFF=1` adds
  it): what is deployed was already tested on staging. If dev has moved on
  since, its undeployed commits are shown *with* their full diff, as a
  warning right before the question.

## Seeing staging from dev

- **Filesystem: a read-only bind of the staging rootfs**, placed by an OCI
  hook (poststart/poststop, decided by hostname) under `/run/vps-mcp/view`,
  which is rshared and mounted into dev with rslave. Only a one-shot
  `mount --bind -o ro` gives a read-only propagated mount; a bind followed by
  a read-only remount, or `ro=recursive`, still allowed writes through dev.
- **Journal: a volume, not part of the view.** In systemd mode Podman mounts
  its own tmpfs on `/var/log/journal`, so logs were lost on restart and the
  rootfs bind did not include them. Every container now gets a
  `<fqdn>-journal` volume there (a mount of one's own replaces Podman's
  tmpfs), and create3 mounts staging's volume read-only into dev at
  `/mnt/stg-journal`. Binding it from the hook was tried and dropped: taken
  from `/proc/<pid>/root/var/log/journal` on the host, the path resolved to
  the *host's* journal.
- **Mail: the host relay BCCs staging's mail** to `stgcapture+<staging>`, and
  a path unit hands each copy to dev's `/srv/stg-mail/`. Considered instead:
  `always_bcc` in staging's Postfix, read through the filesystem view. Kept
  the relay copy because it also catches mail an application sends straight
  to the relay, stays readable while staging is stopped (the view is
  unmounted then), and does not grow staging's disk.

## Forward mode (moving a site without downtime)

- **443 is passed through still encrypted** to the old server (nginx stream),
  so the old site keeps serving with its own certificate while DNS moves.
  The consequence: nothing on 443 can be answered here by path, not even
  `/mcp/` — a single container's MCP connector becomes usable only after
  `unforward`. (Splitting by SNI for a separate MCP name was considered; it
  needs no new mechanism once DNS has moved, because `unforward` with
  `app.d/forward.conf` already answers `/mcp/` here and proxies the rest.)
- **Port 80 answers ACME challenges here first**, falling back to the old
  server (`try_files $uri @old`), so the old server's own renewals keep
  working after DNS moves.
- **Let's Encrypt validates where DNS points**, so a certificate can only be
  obtained after the move. `getcert` first checks that every name reaches
  this container (a random file in the ACME webroot), because each failed
  validation counts against a limit of 5 per hostname per hour.
- **The check resolves names through public DNS** (`dig @1.1.1.1` /
  `@8.8.8.8`, then `curl --resolve`). Inside a container, Podman's resolver
  answers a container hostname with the container's own address, so a plain
  `curl http://<name>/` always succeeded and the check passed while the name
  still pointed at the old server.
- **Zone records on container names.** `zone.sh` rejects A/AAAA/CNAME on a
  name a container serves, except an A record with this host's IP (needed
  where the wildcard does not answer: a name with records below it, e.g.
  `iot0` once `http.iot0` exists) or, while the container forwards, the old
  server's IP (the name points there until the move).

## Names and redirects

- **Deeper names go to the container below the domain**
  (`http.iot0.example.org` → `iot0.example.org-web`). Devices that can only
  speak plain http use a name the certificate does not cover, answered by a
  `listen 80` server block of their own, so they are never redirected to
  https. (Before, the proxies dropped such names.)
- **A Host that does not match the container gets a 302, not a 301.** A
  browser keeps a 301: a hostname that reached the main server block before its own
  was deployed kept being sent to the apex by browsers after the fix.

## Updating running containers

- **`make mcpupdate` also refreshes the helper scripts** (`vps-mcp-mode.sh`,
  `vps-mcp-recv.sh`, `certbot-deploy.sh`, `vps-mcp-init.sh`) in *every*
  container, staging and production included, since they run there too.
  Before, only the image carried them, and a running container kept an old
  `vps-mcp-mode.sh` after `git pull` + `mcpupdate`.
- **`make install-binaries` restarts the proxies.** A running proxy keeps the
  old binary; the socket units hold the listening sockets, so new
  connections wait instead of failing.
