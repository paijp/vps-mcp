/**
 * https://github.com/paijp/vps-mcp
 *
 * vps-mcp full: single-host MCP server with GitHub OAuth login.
 *
 * Authentication uses real GitHub OAuth. Because this is a single-host
 * deployment (one VPS, one owner), the authorization-server role seen by
 * Claude.ai and the GitHub-login broker role live in the same process — there
 * is no separate broker container as in the multi-tenant subdomain edition.
 * The GitHub OAuth App's single callback is this host's /mcp/callback.
 *
 * Endpoints:
 *   - /.well-known/oauth-authorization-server  discovery metadata (PKCE S256, public client)
 *   - /mcp/register   dynamic client registration (RFC 7591); we are a public
 *                     client and never validate client_id
 *   - /mcp/authorize  validates redirect_uri host is claude.ai and PKCE is S256,
 *                     then redirects the browser to GitHub authorize
 *   - /mcp/callback   exchanges the GitHub code (single-use, consumed here) for the
 *                     verified primary email, mints an authorization code bound to
 *                     { challenge, email }, then redirects the browser back to
 *                     claude.ai with that code
 *   - /mcp/token      receives { code, code_verifier }, checks sha256(verifier)
 *                     against the stored challenge, and issues a Bearer only if the
 *                     resolved email matches NOTIFY_EMAIL
 *   - /mcp/sse        SSE transport (Bearer auth)
 *   - /mcp/messages   SSE message channel (Bearer auth)
 *
 * Environment variables (from /etc/vps-mcp/host.env and /etc/vps-mcp/oauth.env):
 *   SUBDOMAIN            – full hostname, e.g. example.com
 *   NOTIFY_EMAIL         – the owner's email; only this GitHub account is allowed
 *   GITHUB_CLIENT_ID     – GitHub OAuth App client id
 *   GITHUB_CLIENT_SECRET – GitHub OAuth App secret
 */

import crypto from "node:crypto";
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { Resolver } from "node:dns/promises";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import express from "express";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

const execFileAsync = promisify(execFile);

const SUBDOMAIN        = process.env.SUBDOMAIN        || "localhost";
const HOST_IP          = process.env.IP              || "";
const NOTIFY_EMAIL     = process.env.NOTIFY_EMAIL     || "";
const GH_CLIENT_ID     = process.env.GITHUB_CLIENT_ID     || "";
const GH_CLIENT_SECRET = process.env.GITHUB_CLIENT_SECRET || "";
const PORT             = 3000;
const EXEC_TIMEOUT     = 60_000;

// GitHub Actions OIDC → file PUT (/deploy). Deploys are accepted from any
// workflow run in the owner's account: only repository_owner_id is checked
// (plus issuer/audience/exp/jti), not the branch or event.
const DEPLOY_BASE_DIR  = process.env.DEPLOY_BASE_DIR || "/srv/deploy";
const DEPLOY_AUDIENCE  = process.env.DEPLOY_AUDIENCE || SUBDOMAIN;
const GH_OIDC_ISSUER   = "https://token.actions.githubusercontent.com";

const MFN = "/etc/mcp-server";

const sha256hex = t => crypto.createHash("sha256").update(t).digest("hex");
// PKCE S256: BASE64URL(SHA256(code_verifier)).
const sha256b64url = t => crypto.createHash("sha256").update(t).digest("base64url");

const encodeState = obj => Buffer.from(JSON.stringify(obj)).toString("base64url");
const decodeState = s => JSON.parse(Buffer.from(String(s), "base64url").toString("utf8"));

const isClaudeRedirect = u => {
  try { return new URL(u).hostname === "claude.ai"; } catch { return false; }
};

// ── "Hot" zones (domains this host actually answers for) ──────────────────────
// This box runs BIND as authoritative for some zones, but a zone file can be
// stale: e.g. a domain migrated to another host while the old zone file lingers
// here. To advertise only domains that genuinely point at THIS host, each zone
// is resolved through an EXTERNAL public resolver (bypassing the local BIND, so
// the answer reflects the registrar's current delegation, not our own zone).
//
// Three-state, to avoid flapping on transient DNS failures:
//   - our IP is among the answers    → hot   (advertise)
//   - resolves, but our IP absent    → cold  (a migration moved it away)
//   - NXDOMAIN / SERVFAIL / timeout  → keep the previous flag (no change)
// The flags persist in ${MFN}/hot_zones.json so "keep previous" survives restarts.
const HOT_FILE  = `${MFN}/hot_zones.json`;
const ZONE_DIRS = ["/etc/bind/zones", "/var/named"];

const extResolver = new Resolver();
extResolver.setServers(["8.8.8.8", "1.1.1.1"]);

// domain -> boolean (hot). Loaded once, refreshed periodically.
let hotZones = (() => {
  try { return JSON.parse(readFileSync(HOT_FILE, "utf8")); } catch { return {}; }
})();

function zoneDomains() {
  for (const dir of ZONE_DIRS) {
    try {
      if (!statSync(dir).isDirectory()) continue;
      return readdirSync(dir)
        .filter(f => f.endsWith(".zone"))
        .map(f => f.slice(0, -5));
    } catch { /* try next dir */ }
  }
  return [];
}

async function refreshHotZones() {
  if (!HOST_IP) return;                       // nothing to compare against
  const next = {};
  for (const domain of zoneDomains()) {
    let addrs = null;
    try { addrs = await extResolver.resolve4(domain); }
    catch { /* NXDOMAIN / SERVFAIL / timeout */ }
    if (addrs && addrs.length) {
      // hot when our IP is among the answers — this host is a valid endpoint
      // for the domain. A fully migrated domain resolves to foreign IPs only
      // (our IP absent) → cold. During a brief new/old overlap it stays hot,
      // which is correct because this host is still serving it then.
      next[domain] = addrs.includes(HOST_IP);
    } else if (domain in hotZones) {
      next[domain] = hotZones[domain];        // resolution failed → keep previous
    }
    // else: unknown domain, first-ever lookup failed → leave it out (cold)
  }
  hotZones = next;
  try { writeFileSync(HOT_FILE, JSON.stringify(hotZones)); } catch { /* best effort */ }
}

// Usage policy appended to every tool description. This connector executes
// commands and touches files on a real, shared VPS, so each tool tells the
// model to seek the user's permission before acting and to treat resources it
// did not itself create as belonging to someone else.
const USAGE_POLICY =
  "\n\nUsage policy: Obtain the user's explicit permission before using this " +
  "connector. When an action would touch a constraint the user specified — for " +
  "example, when a plan fails and you try an alternative — obtain the user's " +
  "permission first. This connector is used by multiple sessions, so confirm " +
  "with the user before deleting, modifying, or stopping resources that belong " +
  "to another session. Treat any resource you cannot be sure you created in " +
  "this session as belonging to another session.";

// Line appended to tool descriptions so Claude can tell which host (and which
// domains) this connector is bound to — guarding against acting on the wrong
// VPS. Also carries the shared-use USAGE_POLICY above.
function hostInfoLine() {
  const hot = Object.keys(hotZones).filter(d => hotZones[d]).sort();
  const ip  = HOST_IP ? ` (IP ${HOST_IP})` : "";
  const dom = hot.length ? ` Domains served here: ${hot.join(", ")}.` : "";
  return `\nThis connector is bound to the VPS ${SUBDOMAIN}${ip}.${dom}` + USAGE_POLICY;
}

// External base URL of this host, derived from the proxied request headers so
// it works regardless of the configured domain.
const baseUrl = req => {
  const host  = req.headers["x-forwarded-host"] || req.headers.host || req.hostname;
  const proto = req.headers["x-forwarded-proto"] || req.protocol;
  return `${proto}://${host}`;
};

// ── GitHub OIDC verification (for /deploy) ────────────────────────────────────
// GitHub publishes its public keys at the JWKS endpoint; jose fetches and caches
// them (and refetches on key rotation). Only the owner bound at GitHub login
// (${MFN}/deploy_owner) may deploy.
const JWKS = createRemoteJWKSet(new URL(`${GH_OIDC_ISSUER}/.well-known/jwks`));

// jti single-use cache for replay protection: jti -> expiry(ms). OIDC tokens
// are short-lived; a used jti is rejected until it expires, then swept.
const usedJti = new Map();
setInterval(() => {
  const now = Date.now();
  for (const [k, exp] of usedJti) if (exp <= now) usedJti.delete(k);
}, 60_000).unref();

// { id, login } persisted at GitHub login. Returns null if not bound yet.
function deployOwner() {
  try { return JSON.parse(readFileSync(`${MFN}/deploy_owner`, "utf8")); }
  catch { return null; }
}

async function verifyDeployToken(jwt) {
  // jwtVerify checks signature (RS256 via JWKS), iss, aud and exp.
  const { payload } = await jwtVerify(jwt, JWKS, {
    issuer:   GH_OIDC_ISSUER,
    audience: DEPLOY_AUDIENCE,
  });
  const owner = deployOwner();
  if (!owner || !owner.id) throw new Error("deploy owner not bound");
  if (String(payload.repository_owner_id) !== String(owner.id))
    throw new Error("owner mismatch");
  // Anti-replay: PUT bodies are not signed, so a captured token could otherwise
  // be replayed within its exp window with different content. Single-use jti
  // closes that. (TLS + short exp already make capture hard.)
  if (payload.jti) {
    if (usedJti.has(payload.jti)) throw new Error("replay");
    usedJti.set(payload.jti, (payload.exp || 0) * 1000);
  }
  return payload;
}

// Resolve a request path under DEPLOY_BASE_DIR, rejecting traversal.
function resolveDeployPath(rel) {
  const dest = path.resolve(DEPLOY_BASE_DIR, rel);
  if (dest !== DEPLOY_BASE_DIR && !dest.startsWith(DEPLOY_BASE_DIR + path.sep))
    return null;
  return dest;
}

async function handleDeploy(req, res) {
  const m = (req.headers.authorization || "").match(/^Bearer\s+(.+)$/i);
  if (!m) return res.status(401).send();
  try {
    await verifyDeployToken(m[1]);
  } catch {
    return res.status(401).send();
  }
  const dest = resolveDeployPath(req.params[0] || "");
  if (!dest) return res.status(400).send();
  try {
    await fs.mkdir(path.dirname(dest), { recursive: true });
    await fs.writeFile(dest, req.body);
    return res.status(200).send("ok");
  } catch (err) {
    return res.status(500).send(String(err.message || err));
  }
}

const app = express();

// Receiver for GitHub Actions deploys. Hosted UNDER the already-proxied
// /mcp/messages prefix so no dedicated nginx location is needed (that location
// already proxies to this server with client_max_body_size 25m). Registered
// BEFORE the JSON/urlencoded parsers below: curl --data-binary defaults to a
// urlencoded content-type, which would otherwise consume the stream.
// type:()=>true makes express.raw accept any content-type.
app.put("/mcp/messages/deploy/*", express.raw({ type: () => true, limit: "25mb" }), handleDeploy);

// Express defaults the JSON body limit to 100KB. write_file delivers the file
// content inside the JSON-RPC request body, so a modest file (the JSON-RPC
// envelope plus string escaping inflate it further) can exceed that and fail
// with PayloadTooLargeError. Raise the limit so large files can be written.
app.use(express.json({ limit: "25mb" }));
app.use(express.urlencoded({ extended: false }));

// ── OAuth discovery ───────────────────────────────────────────────────────────

app.get("/.well-known/oauth-authorization-server", (req, res) => {
  const base = baseUrl(req);
  res.json({
    issuer:                                base,
    authorization_endpoint:               `${base}/mcp/authorize`,
    token_endpoint:                        `${base}/mcp/token`,
    registration_endpoint:                `${base}/mcp/register`,
    token_endpoint_auth_methods_supported: ["none"],
    response_types_supported:             ["code"],
    code_challenge_methods_supported:     ["S256"],
  });
});

// ── Dynamic client registration (RFC 7591) ────────────────────────────────────
// Claude.ai auto-registers a client before starting the flow; without this it
// reports "does not support automatic client registration". We are a public
// client and never validate client_id (PKCE + GitHub email match are the gate),
// so we just mint an id and echo the requested metadata back.

app.post("/mcp/register", (req, res) => {
  const meta = req.body || {};
  res.status(201).json({
    client_id:            crypto.randomBytes(16).toString("hex"),
    client_id_issued_at:  Math.floor(Date.now() / 1000),
    redirect_uris:        Array.isArray(meta.redirect_uris) ? meta.redirect_uris : [],
    token_endpoint_auth_method: "none",
    grant_types:          meta.grant_types   || ["authorization_code"],
    response_types:       meta.response_types || ["code"],
    ...(meta.client_name ? { client_name: meta.client_name } : {}),
    ...(meta.scope       ? { scope:       meta.scope }       : {}),
  });
});

// ── Authorization endpoint ────────────────────────────────────────────────────
// Validates that redirect_uri belongs to claude.ai and PKCE is S256, then
// redirects the browser to GitHub. The PKCE challenge and the claude.ai
// redirect/state are carried through GitHub's `state` parameter.

app.get("/mcp/authorize", (req, res) => {
  const { redirect_uri, state, code_challenge, code_challenge_method } = req.query;
  if (!isClaudeRedirect(redirect_uri))   return res.status(400).send();
  if (code_challenge_method !== "S256")  return res.status(400).send();
  if (!code_challenge)                   return res.status(400).send();
  if (!GH_CLIENT_ID)                     return res.status(500).send();

  const callbackUri = `${baseUrl(req)}/mcp/callback`;
  const ghState = encodeState({
    claude_redirect: redirect_uri,
    claude_state:    state || "",
    challenge:       code_challenge,
  });
  const url = new URL("https://github.com/login/oauth/authorize");
  url.searchParams.set("client_id", GH_CLIENT_ID);
  url.searchParams.set("redirect_uri", callbackUri);
  url.searchParams.set("scope", "user:email");
  url.searchParams.set("state", ghState);
  res.redirect(302, url.toString());
});

// ── GitHub callback ───────────────────────────────────────────────────────────
// GitHub redirects the browser here with a single-use code. We exchange it
// immediately (so the code is dead by the time it sits in browser history),
// fetch the verified primary email, stash it under the PKCE challenge, then
// send the browser back to claude.ai with our own authorization code.

// pending: auth_code -> { challenge, email, createdAt }. In-memory; a login
// completes in one short browser session. Entries are single-use and swept
// after PENDING_TTL.
const pending = new Map();
const PENDING_TTL = 10 * 60_000;
setInterval(() => {
  const now = Date.now();
  for (const [k, v] of pending) if (now - v.createdAt > PENDING_TTL) pending.delete(k);
}, 60_000).unref();

app.get("/mcp/callback", async (req, res) => {
  const { code, state } = req.query;
  let st;
  try { st = decodeState(state); } catch { return res.status(400).send(); }
  if (!isClaudeRedirect(st.claude_redirect)) return res.status(400).send();
  if (!st.challenge || !code)                return res.status(400).send();

  const callbackUri = `${baseUrl(req)}/mcp/callback`;
  try {
    const tokRes = await fetch("https://github.com/login/oauth/access_token", {
      method:  "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body:    JSON.stringify({
        client_id:     GH_CLIENT_ID,
        client_secret: GH_CLIENT_SECRET,
        code,
        redirect_uri:  callbackUri,
      }),
    });
    const tok = await tokRes.json();
    if (!tok.access_token) return res.status(403).send();

    const emailRes = await fetch("https://api.github.com/user/emails", {
      headers: {
        authorization: `Bearer ${tok.access_token}`,
        accept:        "application/vnd.github+json",
        "user-agent":  "vps-mcp",
      },
    });
    const emails = await emailRes.json();
    const primary = Array.isArray(emails)
      ? emails.find(e => e.primary && e.verified)
      : null;
    if (!primary) return res.status(403).send();

    // Also fetch the numeric account id and login, so a successful login can
    // bind this host's /deploy owner (OIDC repository_owner_id) automatically.
    let ghId = "", ghLogin = "";
    try {
      const uRes = await fetch("https://api.github.com/user", {
        headers: {
          authorization: `Bearer ${tok.access_token}`,
          accept:        "application/vnd.github+json",
          "user-agent":  "vps-mcp",
        },
      });
      const u = await uRes.json();
      if (u && u.id) { ghId = String(u.id); ghLogin = String(u.login || ""); }
    } catch { /* non-fatal: deploy owner just won't be set this login */ }

    // Issue our own authorization code, bound to the PKCE challenge and email.
    // It is delivered only to claude.ai (redirect_uri is host-locked above), so
    // an attacker who merely holds a verifier cannot obtain it and thus cannot
    // exchange it — this is what stops login-CSRF / authorization-code fixation.
    const authCode = crypto.randomBytes(32).toString("hex");
    pending.set(authCode, { challenge: st.challenge, email: primary.email, ghId, ghLogin, createdAt: Date.now() });

    const url = new URL(st.claude_redirect);
    url.searchParams.set("code", authCode);
    if (st.claude_state) url.searchParams.set("state", st.claude_state);
    res.set("Referrer-Policy", "no-referrer");
    return res.redirect(302, url.toString());
  } catch {
    return res.status(502).send();
  }
});

// ── Token endpoint ────────────────────────────────────────────────────────────
// Exchanges { code, code_verifier } for a Bearer. The caller must present both
// the authorization code (delivered only to claude.ai) and the matching PKCE
// verifier. A Bearer is issued only if the resolved GitHub email matches
// NOTIFY_EMAIL. The code is single-use.

app.post("/mcp/token", (req, res) => {
  const { code, code_verifier } = req.body;
  if (!code || !code_verifier) return res.status(400).send();

  const entry = pending.get(code);
  if (!entry) return res.status(403).send();

  const a = Buffer.from(sha256b64url(code_verifier));
  const b = Buffer.from(entry.challenge);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b))
    return res.status(403).send();
  pending.delete(code);

  if (!entry.email || entry.email.toLowerCase() !== NOTIFY_EMAIL.toLowerCase())
    return res.status(403).send();

  // Opt-in fixed token: if a token file exists (root-placed, mode 600), reuse
  // its contents instead of minting a random one, so the same Bearer can be
  // issued repeatedly (e.g. shared across accounts / stable reconnection). The
  // GitHub-login gate above still guards issuance; the trade-off is that the
  // plaintext token then lives at rest, weakening the hash-only property, and
  // login no longer rotates it. Revoke by deleting the token file and the hash.
  // A missing, empty, or too-short file falls back to a fresh random token.
  let token;
  try {
    const t = readFileSync(`${MFN}/token`, "utf8").trim();
    token = t.length >= 32 ? t : crypto.randomBytes(32).toString("hex");
  } catch {
    token = crypto.randomBytes(32).toString("hex");
  }
  writeFileSync(`${MFN}/hash`, sha256hex(token), { mode: 0o600 });

  // Bind the /deploy owner to this verified GitHub account (numeric id is
  // immutable; login is stored for display only). Enables GitHub Actions OIDC
  // PUT /deploy without any manual configuration.
  if (entry.ghId) {
    writeFileSync(
      `${MFN}/deploy_owner`,
      JSON.stringify({ id: entry.ghId, login: entry.ghLogin }),
      { mode: 0o600 }
    );
  }

  if (NOTIFY_EMAIL) {
    const m = spawn("/usr/sbin/sendmail", ["-f", `noreply@${SUBDOMAIN}`, NOTIFY_EMAIL]);
    m.stdin.end(
      `From: noreply@${SUBDOMAIN}\r\nTo: ${NOTIFY_EMAIL}\r\nSubject: MCP token issued\r\n\r\n` +
      `A Bearer token was issued after GitHub login as ${entry.email}.\r\n`
    );
  }

  res.json({ access_token: token, token_type: "Bearer" });
});

// ── Bearer auth middleware ────────────────────────────────────────────────────

function auth(req, res, next) {
  const t = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  let h;
  try { h = readFileSync(`${MFN}/hash`, "utf8").trim(); } catch {
    return res.status(401).send();
  }
  const hb = Buffer.from(h);
  const tb = Buffer.from(sha256hex(t));
  if (hb.length !== tb.length || !crypto.timingSafeEqual(hb, tb))
    return res.status(401).send();
  next();
}

// ── MCP server ────────────────────────────────────────────────────────────────
// A fresh McpServer is built per SSE connection: a single Protocol instance can
// only be bound to one transport at a time, so sharing it across reconnects
// throws "Already connected to a transport" and crashes the process.

function createMcpServer() {
  const mcp = new McpServer({ name: "vps-mcp", version: "1.0.0" });

  mcp.tool(
    "exec_command",
    `Execute a shell command on the VPS (${SUBDOMAIN}). Returns stdout and stderr.` +
      hostInfoLine(),
    { command: z.string().describe("Shell command to run") },
    async ({ command }) => {
      try {
        const { stdout, stderr } = await execFileAsync(
          "/bin/bash", ["-c", command],
          { timeout: EXEC_TIMEOUT, maxBuffer: 10 * 1024 * 1024 }
        );
        return {
          content: [{ type: "text", text: stdout + (stderr ? `\n[stderr]\n${stderr}` : "") }],
        };
      } catch (err) {
        const msg = err.stdout
          ? err.stdout + (err.stderr ? `\n[stderr]\n${err.stderr}` : "")
          : err.message;
        return { content: [{ type: "text", text: `[error]\n${msg}` }], isError: true };
      }
    }
  );

  mcp.tool(
    "read_file",
    `Read a file from the VPS (${SUBDOMAIN}) filesystem.` +
      hostInfoLine(),
    { path: z.string().describe("Absolute path to the file") },
    async ({ path: filePath }) => {
      try {
        const content = await fs.readFile(filePath, "utf8");
        return { content: [{ type: "text", text: content }] };
      } catch (err) {
        return { content: [{ type: "text", text: `[error] ${err.message}` }], isError: true };
      }
    }
  );

  mcp.tool(
    "write_file",
    `Write content to a file on the VPS (${SUBDOMAIN}) filesystem. ` +
      "If the same content will also live in a GitHub repository, prefer " +
      "committing to GitHub and deploying via GitHub Actions unless the user " +
      "asks otherwise — writing large files directly through this tool costs " +
      "more tokens, takes longer, and fails more often." +
      hostInfoLine(),
    {
      path:    z.string().describe("Absolute path to the file"),
      content: z.string().describe("Content to write"),
    },
    async ({ path: filePath, content }) => {
      try {
        await fs.mkdir(path.dirname(filePath), { recursive: true });
        await fs.writeFile(filePath, content, "utf8");
        return { content: [{ type: "text", text: "ok" }] };
      } catch (err) {
        return { content: [{ type: "text", text: `[error] ${err.message}` }], isError: true };
      }
    }
  );

  mcp.tool(
    "nginx_reload",
    `Reload the nginx configuration on the VPS (${SUBDOMAIN}). ` +
      "Always use this instead of running " +
      "'nginx -s reload' / 'systemctl reload nginx' via exec_command: the MCP " +
      "SSE connection is proxied through nginx, so a synchronous reload can " +
      "interrupt it before the tool result is delivered and stall the client " +
      "until timeout. This validates the config, returns immediately, then " +
      "defers the actual reload so the result is flushed first." +
      hostInfoLine(),
    {},
    async () => {
      // Validate the config before touching the running server. nginx -t
      // writes its report to stderr on both success and failure.
      let report;
      try {
        const { stderr } = await execFileAsync("/usr/sbin/nginx", ["-t"]);
        report = stderr;
      } catch (err) {
        return {
          content: [{ type: "text", text: `[error] nginx config test failed:\n${err.stderr || err.message}` }],
          isError: true,
        };
      }
      // Defer the reload so this response reaches the client first; reloading
      // can briefly disrupt the SSE connection that carries tool results.
      setTimeout(() => {
        execFile("/usr/bin/systemctl", ["reload", "nginx"], (err, _out, stderr) => {
          if (err) console.error(`nginx_reload: reload failed: ${stderr || err.message}`);
        });
      }, 1000);
      return { content: [{ type: "text", text: `nginx config valid; reload scheduled\n${report}` }] };
    }
  );

  mcp.tool(
    "deploy_setup",
    "Generate a ready-to-commit GitHub Actions workflow that deploys files from " +
      `a repository to this host (${SUBDOMAIN}) over HTTPS using GitHub OIDC (no stored secret). ` +
      "Files are PUT to /deploy and land under the host's deploy directory. " +
      "Commit the returned YAML to .github/workflows/deploy.yml in a repository " +
      "owned by the GitHub account that logged in here. Deploys are accepted from " +
      "any branch or event in that account (only the owner is checked)." +
      hostInfoLine(),
    {
      src_dir:     z.string().optional().describe("Directory in the repo to upload (default: dist)"),
      dest_prefix: z.string().optional().describe("Path prefix under the deploy dir (default: site)"),
      build_workflow: z.string().optional().describe(
        "Name of a build workflow that produces the files. If set, the deploy " +
        "triggers on that workflow's completion (workflow_run) instead of push — " +
        "needed because a push made by another workflow's GITHUB_TOKEN does not " +
        "trigger push-based workflows."),
    },
    async ({ src_dir, dest_prefix, build_workflow }) => {
      const owner = deployOwner();
      const src  = src_dir     || "dist";
      const dest = dest_prefix || "site";
      // Built from double-quoted strings so the workflow's own ${{ }} / ${VAR}
      // are emitted literally (not interpolated as JS template substitutions).
      // Trigger: GITHUB_TOKEN-driven pushes do NOT trigger push workflows
      // (GitHub blocks workflow chaining), so when the files come from another
      // workflow, use workflow_run instead.
      const trigger = build_workflow
        ? [
            "on:",
            "  # Runs after the build workflow finishes. workflow_run is required",
            "  # because a push made by another workflow's GITHUB_TOKEN does NOT",
            "  # trigger push-based workflows. (Note: workflow_run runs in the",
            "  # default-branch context — checkout the right ref or download the",
            "  # build's artifacts as needed.)",
            "  workflow_run:",
            "    workflows: [\"" + build_workflow + "\"]",
            "    types: [completed]",
          ]
        : [
            "on:",
            "  # Triggers on a HUMAN push to " + src + "/. A push made by ANOTHER",
            "  # workflow using the default GITHUB_TOKEN will NOT trigger this",
            "  # (GitHub blocks workflow chaining). If these files are produced by",
            "  # a build workflow, either add the deploy steps directly to that",
            "  # workflow, or call deploy_setup with build_workflow set to use the",
            "  # workflow_run trigger instead.",
            "  push:",
            "    branches: [main]",
            "    paths: ['" + src + "/**']",
          ];
      const yaml = [
        "name: deploy-to-vps",
        ...trigger,
        "",
        "permissions:",
        "  id-token: write          # required to mint the OIDC token",
        "  contents: read",
        "",
        "env:",
        "  VPS_HOST: " + DEPLOY_AUDIENCE + "      # this host (OIDC audience)",
        "  SRC_DIR: " + src,
        "  DEST_PREFIX: " + dest + "        # files land under <deploy dir>/<DEST_PREFIX>/",
        "",
        "jobs:",
        "  deploy:",
        "    runs-on: ubuntu-latest",
        "    steps:",
        "      - uses: actions/checkout@v4",
        "",
        "      - name: Mint GitHub OIDC token (audience = VPS host)",
        "        id: oidc",
        "        run: |",
        "          TOKEN=$(curl -sS \\",
        "            -H \"Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN\" \\",
        "            \"$ACTIONS_ID_TOKEN_REQUEST_URL&audience=${VPS_HOST}\" | jq -r '.value')",
        "          echo \"::add-mask::$TOKEN\"",
        "          echo \"token=$TOKEN\" >> \"$GITHUB_OUTPUT\"",
        "",
        "      - name: PUT files to VPS /deploy",
        "        env:",
        "          TOKEN: ${{ steps.oidc.outputs.token }}",
        "        run: |",
        "          set -euo pipefail",
        "          cd \"$SRC_DIR\"",
        "          find . -type f -print0 | while IFS= read -r -d '' f; do",
        "            rel=\"${f#./}\"",
        "            echo \"PUT $rel\"",
        "            code=$(curl -sS -o /dev/null -w '%{http_code}' \\",
        "              -X PUT --data-binary @\"$f\" \\",
        "              -H \"Authorization: Bearer $TOKEN\" \\",
        "              -H 'Content-Type: application/octet-stream' \\",
        "              \"https://${VPS_HOST}/mcp/messages/deploy/${DEST_PREFIX}/${rel}\")",
        "            test \"$code\" = \"200\" || { echo \"failed: $rel -> HTTP $code\"; exit 1; }",
        "          done",
      ].join("\n");

      const ownerLine = owner && owner.id
        ? `Deploy owner bound to GitHub @${owner.login || "?"} (id ${owner.id}); ` +
          `OIDC tokens from any repo under this account are accepted.`
        : `WARNING: no deploy owner is bound yet. Complete a GitHub login through ` +
          `the connector first, then re-run deploy_setup.`;

      const triggerNote = build_workflow
        ? `Triggered on completion of the "${build_workflow}" workflow (workflow_run).`
        : `Triggered on a human push to ${src}/. IMPORTANT: a push made by another ` +
          `workflow using the default GITHUB_TOKEN will NOT trigger this (GitHub blocks ` +
          `workflow chaining) — if ${src}/ is written by a build workflow, either add ` +
          `these deploy steps to that workflow, or re-run deploy_setup with ` +
          `build_workflow set to use the workflow_run trigger.`;

      const instructions =
        `${ownerLine}\n\n` +
        `Commit the YAML below to .github/workflows/deploy.yml in a repository owned ` +
        `by that account. Files in ${src}/ are uploaded to ` +
        `https://${DEPLOY_AUDIENCE}/mcp/messages/deploy/${dest}/<path> (server dir ` +
        `${DEPLOY_BASE_DIR}/${dest}/). No secret is stored — auth is the GitHub OIDC token.\n\n` +
        `${triggerNote}\n\n` +
        "```yaml\n" + yaml + "\n```\n";

      return { content: [{ type: "text", text: instructions }] };
    }
  );

  return mcp;
}

// ── Streamable HTTP transport ─────────────────────────────────────────────────
// Claude.ai probes the connector URL with a POST (Streamable HTTP) before
// falling back to legacy SSE; when this returned 404 the fallback did not
// always happen and the connector stayed unusable. Stateless mode: a fresh
// server+transport pair per request, no session tracking needed.

app.post("/mcp/sse", auth, async (req, res) => {
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  const mcp = createMcpServer();
  res.on("close", () => {
    transport.close();
    mcp.close();
  });
  await mcp.connect(transport);
  await transport.handleRequest(req, res, req.body);
});

// ── SSE transport (legacy) ────────────────────────────────────────────────────

const transports = new Map();

app.get("/mcp/sse", auth, async (req, res) => {
  const transport = new SSEServerTransport("/mcp/messages", res);
  transports.set(transport.sessionId, transport);
  req.on("close", () => {
    transports.delete(transport.sessionId);
    transport.close();
  });
  const mcp = createMcpServer();
  await mcp.connect(transport);
});

app.post("/mcp/messages", auth, async (req, res) => {
  const transport = transports.get(req.query.sessionId);
  if (!transport) return res.status(404).json({ error: "session not found" });
  await transport.handlePostMessage(req, res, req.body);
});

// ── Start ─────────────────────────────────────────────────────────────────────

app.listen(PORT, "127.0.0.1", () => {
  console.log(`vps-mcp listening on 127.0.0.1:${PORT} (subdomain=${SUBDOMAIN})`);
});

// Determine which zones are "hot" now and re-check periodically. A fresh
// McpServer (and thus a fresh tool description via hostInfoLine) is built per
// SSE connection, so each new connection picks up the latest result.
refreshHotZones().catch(() => {});
setInterval(() => { refreshHotZones().catch(() => {}); }, 10 * 60_000).unref();
