# vps-mcp

Build a Claude.ai MCP server on a Sakura VPS, giving Claude control over the host.

This repository hosts **three editions** of the project. Pick the one that matches how
you want to deploy and operate:

| Edition | Directory | Summary |
|---|---|---|
| **Startup script** | [`startupscript/`](startupscript/README.md) | Single-host edition deployed via Sakura's "My Scripts" startup script — a single condensed file (subject to the ~10,000-character My-Scripts limit). Easiest to bootstrap with no SSH. |
| **Full** | [`full/`](full/) | Single-host edition as readable, multi-file source (Makefile-based deploy, GitHub OAuth login). New features land here first; because of the character limit, the startup-script edition will not always track it. |
| **Subdomain** | [`subdomain/`](subdomain/README.md) | Multi-tenant edition: a broker plus per-tenant containers served under subdomains. |

The `startupscript/` and `full/` editions are two forms of the same single-host design;
the `full/` source is the readable reference, while the startup script is the condensed
artifact you paste into the Sakura control panel. They are expected to diverge over time,
so each edition keeps its own README.

## Security (read before deploying any edition)

These servers provide **root-level shell execution (`exec_command`) via MCP** by design,
to give Claude full control over a disposable VPS.

- **Token leakage = root access leakage.** Treat every credential accordingly.
- **Do not place SSH keys on the server** to reach other hosts — root here means access to
  any private key stored here, and to every server that key can reach.
- If you receive a suspicious token-issuance notification, **discard the server and rebuild
  from scratch** (post-compromise mitigation is meaningless).
- VPS operations via Claude are **at your own risk**: irreversible actions (file deletion,
  config destruction, charge-incurring operations) are possible.

See each edition's README for its full threat model and operational guidance — note that the
**subdomain** edition adds multi-tenant concerns (tenant isolation) that the single-host
editions do not have, so do not apply one edition's assumptions to another.

## License

See [`LICENSE`](LICENSE).
