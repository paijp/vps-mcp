# vps-mcp

Startup scripts for building a Claude.ai MCP server on Sakura VPS (RockyLinux 9).

> This code and documentation was written by Claude Sonnet 4.6 and Opus 4.7.

> **Note:** The startup-script edition and the [`full/`](../full/) edition share the same
> single-host design. Because of the Sakura "My Scripts" character limit, new features land
> in the `full/` edition first and the two are expected to diverge — for the most up-to-date
> behavior, refer to the `full/` edition.

## Security Policy

These scripts provide root-level shell execution (`exec_command`) via MCP. This is not a bug — it is by design, to give Claude full control over a single VPS.

- Token leakage = root access leakage
- Defense consists of only two layers: "protecting CLIENT_SECRET" and "detection via token-issuance notification email"
- If you receive a suspicious issuance notification, discard the server and rebuild from scratch
- Multi-layer defense is intentionally omitted (mitigation after a breach is meaningless)
- The `/token` endpoint is restricted to claude.ai's IP range (160.79.104.0/21)
  (Source: <https://platform.claude.com/docs/en/api/ip-addresses>)

VPS operations via Claude are **at your own risk**. Depending on the instructions and circumstances, irreversible actions such as file deletion, configuration destruction, or charge-incurring operations may occur. Please use with full awareness of these risks.

**Do not place SSH keys on this server to log into other servers.** Root access on this VPS means full access to any private key stored here — and by extension, to every server that key can reach. Don't do it! ...Seriously, don't! ...Well, if you really want to, at least make sure those other servers are equally disposable.

Also note that on Sonnet 4.6, chained cross-server instructions such as "use connector A to SSH into server B, then do X on server B" tend not to work reliably.

## Quick Start

### 1. Prepare the VPS

Sign up for a Sakura VPS plan with at least 512MB of memory (skip this if you are repurposing an existing VPS). For new contracts, install with default OS and settings first (you cannot get an IP address without installing). Note that newly contracted accounts cannot send email for a period (72 hours at time of writing), so we recommend waiting 72 hours before proceeding with the verification steps below. Also prepare a domain name in advance.

### 2. DNS Configuration (do this first)

Before running the startup script, ensure your domain resolves to the VPS IP address. If DNS is not working, certbot will fail to obtain a Let's Encrypt certificate and HTTPS access to the MCP server will not be possible.

There are two approaches: using this VPS as the nameserver, or pointing an A record from an existing nameserver.

**(A) Using this VPS as the nameserver**

Configure the following at your registrar:

- Point the NS record to `ns1.<DOMAIN>`
- Register a glue record (A record for `ns1.<DOMAIN>`) with the VPS IP
- In Sakura's domain control panel, select "Use as secondary nameserver" and register the VPS IP

Set the `NS1_IP` startup script parameter to the VPS's global IPv4 address (see below). The VPS will generate zone file entries for `@ IN A`, `ns1 IN A` (glue record), and `* IN A` (wildcard). Since private IPs may be assigned when multiple NICs are present, the global IP confirmed in the Sakura control panel is specified explicitly.

The wildcard record (`* IN A`) means you can serve new subdomains like `sub.example.com` immediately with just an nginx configuration change — no DNS record registration or propagation wait needed.

**(B) Using an existing nameserver**

Set an A record for your domain to the VPS's global IPv4 address. Set the `NS1_IP` startup script parameter to the same VPS IP (the script also sets up BIND, but DNS queries will be handled by the existing nameserver).

Verify DNS propagation before proceeding to the next step (e.g., `dig @8.8.8.8 <DOMAIN>`).

Note: IPv6 is disabled at the OS level (`net.ipv6.conf.all.disable_ipv6 = 1`). Even if the Sakura VPS control panel shows a global IPv6 address, the kernel, nginx, and Node.js will not process IPv6 packets.

### 3. Register the Startup Script

Register `sakura-rocky9-root-dns.txt` in "My Scripts" in the Sakura VPS control panel. Set the following parameters:

| Parameter | Description | Example |
|---|---|---|
| `DOMAIN` | Domain name | `example.com` |
| `NS1_IP` | This VPS's global IPv4 address | `153.126.xxx.xxx` |
| `CLIENT_SECRET` | OAuth2 client secret (recommended: random string of 12+ characters) | randomly generated value |
| `EMAIL` | Let's Encrypt notification email / startup log destination / token issuance notification | `you@example.com` |

#### About CLIENT_SECRET and CLIENT_ID values

`CLIENT_SECRET` is set as a parameter. `CLIENT_ID` is not stored on the server — it is the value you enter in the Claude.ai connector in a later step. **Generate new random values for every server build.**

- **CLIENT_SECRET**: Random string of 12+ characters recommended
- **CLIENT_ID**: **6–8 digit number** (interpreted as an integer on the `/token` side)

Do not reuse values from previous builds. Old values remain in token notification emails and startup script history, which could provide a foothold if that account is compromised in the future.

**Do not use easily guessable values for CLIENT_ID:**

- **Today's date** (e.g., `20260524`)
- Birthdays, phone numbers, sequential numbers, repeating digits
- Values used in previous server builds

These are prime candidates that attackers try first during stealth intrusion. See attack scenario 2.1 in the Expert Notes section for details. Recommended: generate a random 8-digit number with `node -e "console.log(require('crypto').randomInt(10000000, 100000000))"`.

CLIENT_ID specification details:

- Accepted values: 6–8 digit integers (e.g., `123456`, `78451293`)
- Rejected values: empty string, `0`, strings containing letters, `null`, `undefined`, objects, etc.
- **Leading zeros are stripped** (e.g., `00123456` → treated as `123456`). Avoid values starting with zero
- Decimals and exponential notation (e.g., `1e7`) are parsed as numbers, but plain 6–8 digit integers are recommended
- The numeric value is output as-is in the email subject (e.g., `MCP token issued client_id=78451293`)

`client_id` is restricted to digits only to avoid it becoming a spam classification trigger in email subjects. See the Expert Notes section for design rationale.

### 4. Reinstall the OS

In the Sakura VPS control panel, select the target server and choose "Reinstall OS." Select RockyLinux 9, specify the startup script and parameters configured above, and run the installation.

After installation completes, the startup script runs automatically. Within a few minutes to 10 minutes, you will receive a setup completion notification email at the registered address.

If you do not receive the completion email, DNS propagation may not have finished, causing certbot to fail to obtain a Let's Encrypt certificate. **If you have configured an SSH public key**, log in via SSH and run certbot manually:

```bash
certbot --nginx --non-interactive --agree-tos --email <EMAIL> -d <DOMAIN>
```

If SSH is not available, either wait for DNS propagation and redo the OS reinstallation, or wait and check the server-side certbot auto-retry (`systemctl status certbot-renew.timer`, etc.).

### 5. Register the Claude.ai Connector

In Claude.ai:

```
Customize → Connectors → Add → Custom Connector
URL:           https://<DOMAIN>/mcp/sse
client_id:     <6–8 digit number from step 3>
client_secret: <CLIENT_SECRET set in step 3>
```

**Important**: For security reasons, access tokens are issued only once at the initial connection. If you delete the Claude.ai connector or the access token is lost for any reason, re-setup (OS reinstallation) may be required. Do not casually delete the connector after creation.

### 6. Verification at Connection (Most Important)

When you connect, a token issuance notification email will arrive. **Verify that the `client_id=***` in the email subject exactly matches the value you set in step 3.**

Items to verify:

- **Does the `client_id=***` in the email subject exactly match the value you configured?** ← Most important
- Did the email arrive before you connected?
- Did two or more emails arrive?

If any of these apply, an unauthorized initial connection may have occurred via CLIENT_SECRET brute-force. **Immediately discard the server and rebuild with new CLIENT_SECRET / CLIENT_ID** (see the next section for specific steps).

Note: An attacker who gains root access could temporarily disable the email sending function to suppress the second email notification (see Expert Notes 2.1). Therefore, "did two emails arrive" and "did it arrive before my action" are supplementary signals only. **Exact match of `client_id` is the essential detection signal.**

### 7. Start Using

You can now operate the VPS from Claude.ai. For example, you can give instructions like "Use `<connector name>` to create an under-construction page on the web server."

As noted above, access tokens are issued only once at initial connection. **Be careful not to delete the Claude.ai connector** (losing it requires re-setup).

VPS operations via Claude are **at your own risk**. Depending on the instructions and circumstances, irreversible actions such as file deletion, configuration destruction, or charge-incurring operations may occur. Please use with full awareness of these risks.

## Response to Unauthorized Access Detection

**Important: Simply "resetting the secret/token" is insufficient.** If an attacker has executed `exec_command` even once, they can plant persistent backdoors anywhere — cron, systemd units, SSH keys, iptables, kernel modules, etc. — making it virtually impossible to return the OS to a trustworthy state. Discard the VPS instance itself.

Specific steps:

1. **Delete the claude.ai connector** — Settings → Integrations → delete the connector
2. **Delete the server in the Sakura VPS control panel** — Execute "Delete server" (complete deletion; stopping is not enough)
3. **Remove or retire DNS records** — If reusing the same domain, wait for TTL to expire to reduce the risk of man-in-the-middle attacks using cached DNS
4. **Set up a new VPS** — In the startup script, specify **new** CLIENT_SECRET / CLIENT_ID / EMAIL. Never reuse old values
5. **If reusing the same domain**, update DNS to the new VPS IP. In addition to the A record, also update the glue record for ns1
6. **Re-register the claude.ai connector** — With the new credentials

## File List

| File | Description |
|---|---|
| `sakura-rocky9-root-dns.txt` | Startup script for RockyLinux 9 (BIND + MCP + Nginx + SSL, no comments) |
| `sakura-rocky9-root-dns-withcomment.txt` | Same as above (with comments, for reference and editing) |

Sakura VPS startup scripts have a character limit of approximately 10,000 characters, so comments are omitted and long strings are shortened using variables. If this still becomes insufficient (not yet implemented to maintain readability), further reduction methods include stripping unnecessary spaces.

## Setup Overview

The script automatically builds the following:

1. Swapfile (1GB)
2. Node.js 20 + MCP server (express + @modelcontextprotocol/sdk)
3. BIND (primary DNS) + automatic zone file generation
4. Nginx (reverse proxy, SSE-compatible)
5. certbot (HTTP-01 method, Let's Encrypt SSL auto-acquisition and renewal)
6. firewalld (ssh/http/https/udp53/tcp53/tcp3000)
7. dnf-automatic (security update automation)
8. fail2ban (SSH brute-force protection)
9. Weekly reboot (Sunday 3:00 AM, for applying kernel updates)

## OAuth2 Authentication Flow

The server formally follows the OAuth2 `authorization_code` flow, but in practice authentication is only the presentation of `client_secret` to `/token` (see Expert Notes for design details).

```
1. GET /.well-known/oauth-authorization-server
   → claude.ai auto-discovers endpoints

2. GET /authorize
   → 302 redirect only if redirect_uri host is "claude.ai",
     otherwise 400 (Open Redirect protection)
   → code returns fixed value "x" (functions only as a formality, not as an authorization code)

3. POST /token { client_secret: "...", client_id: <number>, code: "x", ... }
   → Compared against secret file → 403 if mismatch
   → client_id cast to number with +v; 403 if 0 or NaN
   → Secret file deleted
   → Token file read → hash file (sha256) written → token file deleted
   → Token issuance notification email sent (subject includes client_id=<number>)
   → Token returned after 5 seconds (to increase probability of email delivery completion)
   → Token issued only once (403 after secret file deletion)

4. GET /mcp/sse { Authorization: Bearer <token> }
   → Token sha256-hashed and compared to hash file with timingSafeEqual
   → SSE connection established on match
```

## MCP Tools

| Tool | Function |
|---|---|
| `exec_command` | Execute shell commands on the VPS (root privileges, 30-second timeout) |
| `nginx_reload` | Reload Nginx (runs 2 seconds after config test; SSE session will disconnect) |

## Zone Transfer

Zone transfer source IPs from Sakura's secondary DNS are fixed:

- allow-transfer: `210.188.224.9` / `210.224.172.13`
- also-notify: `61.211.236.1` (ns1.dns.ne.jp) / `133.167.21.1` (ns2.dns.ne.jp)

Reference: [Sakura Support - How to edit zone information](https://help.sakura.ad.jp/domain/2302/)

## Security Measures Implemented

| Item | Measure |
|---|---|
| Authentication | OAuth2 format (authorization_code flow); effectively a one-time client_secret exchange |
| Open Redirect | `/authorize` only allows redirect_uri with host `claude.ai` |
| Token issuance | First connection only (403 after secret file deletion) |
| Token authentication | sha256 hash comparison with `crypto.timingSafeEqual` for timing attack protection |
| Token issuance notification | Email sent; subject includes client_id (enables immediate detection of suspicious connections) |
| Token response | 5-second delay (to increase email delivery probability; not a timing attack countermeasure) |
| client_id sanitization | Cast with `+v`; 403 for 0/NaN (prevents spam classification trigger strings) |
| `/token` IP address restriction | Only claude.ai IP range (160.79.104.0/21) allowed |
| Email sending | `spawn` with argv array format to prevent shell injection |
| MCP log stdout | Nginx `access_log off` (for MCP paths) |
| IPv6 | Completely disabled at OS level (`disable_ipv6 = 1`) |
| SSH brute-force protection | fail2ban (10-minute ban after 5 failures) |
| Open resolver | `allow-recursion { 127.0.0.1; }` |
| Security auto-update | dnf-automatic (security only) |
| Kernel update | Weekly reboot (Sunday 3:00 AM) |

---

# Expert Notes

## 1. Design Essence: A One-Time API Key Issuance System Using the OAuth2 Interface

This server declares "OAuth2 authorization_code + PKCE flow" in its metadata, but **does not actually implement the OAuth2 authorization flow**. The essence is:

**Reality**:

- User presents a pre-configured `CLIENT_SECRET` to `/token`
- If it matches, a one-time `access_token` (UUID) is returned
- Subsequently, that token is presented as an API key via the `Authorization: Bearer` header

**Where OAuth2 elements are "form only"**:

| Element | Declared | Implementation |
|---|---|---|
| `/authorize` | Authorization endpoint | Pass-through except for redirect_uri validation; `code=x` fixed |
| Authorization code (code) | Temporary authorization proof | Value is ignored; not validated at `/token` |
| PKCE (code_challenge) | Client authentication enhancement | `S256` declared in metadata; not implemented |
| grant_type | Flow identifier | Not validated at `/token` |
| Token expiry | Access control | Indefinite (permanent) |
| refresh_token | Token renewal | Not issued; not supported |

**Why this design**:

The claude.ai connector expects an OAuth2 interface. Therefore:

- A metadata endpoint must be provided to declare "I am an OAuth2 server"
- claude.ai accesses `/authorize` → `/token` in that order
- Superficially following that flow satisfies the claude.ai side

On top of that, the substance of the authorization flow is reduced to just "secret presentation," discarding complex state management (authorization code storage, PKCE verification, expiry management, refresh handling). This aligns with the design goals of **no SSH required, minimal state, minimal logic**.

More precisely:

> **OAuth2 client_credentials grant behavior implemented using the authorization_code grant interface.** The authorization code is meaningless, tokens are API keys, and re-issuance is done via file operations.

If claude.ai directly supports `client_credentials` in the future, `/authorize` can be removed for further simplification.

## 2. Attack Scenarios Considered

Attack scenarios considered during the design of this script, along with their assessments.

### 2.1 Stealth Intrusion Scenario (Central Threat)

**Attack**: An attacker who has broken the secret consumes `/token` before the legitimate user, writes back a new secret/token, and temporarily disables the email sending function, gaining root access without the legitimate user noticing.

```
1. Attacker breaks CLIENT_SECRET (dictionary attack, guessing, or leakage)
2. Attacker hits /token to obtain access_token_A
   → At this point, one email fires (with attacker-specified client_id)
3. Attacker gains root access via exec_command
4. Attacker writes back the secret (same value) and a new token_B
5. Attacker functionally disables email sending:
   - e.g., comment out the spawn line in /opt/mcp-server/index.mjs and restart the service (fastest)
   - e.g., temporarily replace /bin/mail with a dummy binary that only runs exit(0)
   - e.g., break postfix relay configuration
   - e.g., overwrite the spawn target path
6. Later, the legitimate user hits /token → token_B is returned
   → Normally an email would fire here, but step 5's tampering prevents it from being sent
7. Attacker restores email sending (via timer, file watcher, detecting own email delivery completion, etc.)
8. Legitimate user is in a state of "having received only one email"
9. If the client_id in that one email matches the user's expected value, the user mistakenly treats it as a legitimate notification
10. Attacker has stealthily persisted and shares token_B with the user
```

**Last line of defense**: The `client_id` value in the single email must be unpredictable to the attacker in advance.

- The legitimate user knows the client_id they configured
- The attacker doesn't know the client_id (it's not stored on the server)
- Attacker hits with a random value → "unfamiliar client_id" appears in notification email → legitimate user detects anomaly
- Attacker tries to guess "values the user might pick" → if the user uses **common values**, there's a chance of success

**Therefore, choosing a value that is difficult to guess for CLIENT_ID is fundamentally important.** "Two emails arrived" and "arrived before I connected" are additional detection signals, but if the attacker restricts it to one email as in step 5, these signals don't function. The unpredictability of `client_id` becomes the last line of defense.

### 2.2 Notification Blocking Attack (Serious Secondary Threat)

**Attack**: During step 5 of 2.1 above, the attacker manipulates the `client_id` field to cause email sending to fail. If no email arrives, the stealth intrusion succeeds.

Specific vectors considered:

| Vector | Result | Assessment |
|---|---|---|
| NUL byte insertion | Node.js `spawn` throws `ERR_INVALID_ARG_VALUE` synchronously | Blocks notification AND token issuance fails (setTimeout not registered on throw path, r.json not called) → DoS only |
| String exceeding 1MB | `execve` throws `E2BIG` exceeding `ARG_MAX` | Same as above |
| Objects like `{toString: 1}` | Throw during String conversion in template literal | Same as above |
| Spam words (`VIAGRA`, etc.) | Recipient-side classification by spam filter | **Detection signal destroyed**, risk of user missing it |
| CRLF (`\r\n`) header injection | s-nail automatically removes NL/CR | Not successful |
| Argument injection (`--option`-style) | argv array format in `spawn` prevents argv boundary movement | Not successful |
| Excessively long subject | Spam filter reaction, MUA truncation | **Detection signal degraded** |

**Defense**: `client_id` cast to number with `+v`, 403 on `!cid`. Restricting to digits only:

- Prevents spam words (letter-based) from appearing in subject
- Eliminates control characters and NUL bytes
- Subject length is automatically short (8 digits max)
- Numeric email subjects don't trigger spam filters

The "token not issued and notification not sent" on throw path is more acceptable than "token issued but notification not sent" (DoS only; intrusion doesn't succeed).

### 2.3 Open Redirect via Phishing

**Attack**: Specify an arbitrary site in `/authorize`'s `redirect_uri` to redirect claude.ai users to a phishing site. Since `/authorize` URLs are recognized as legitimate sites by OAuth convention, users may be less vigilant.

**Defense**: `new URL(redirect_uri).host !== "claude.ai"` returns 400.

Verified bypass attempts (all failed):

- `https://claude.ai@evil.com/` (userinfo) → host determination treats it as evil.com → 400
- `https://claude.ai.evil.com/` (subdomain) → 400
- `https://evilclaude.ai/` (suffix) → 400
- `javascript:` / `data:` URL → 400
- Control character (`\t`, `\r`, `\n`, `\0`) insertion → URL API removes them before host determination → 400
- IDN homoglyphs (`claude.ai。evil.com`) → 400

Passing/gray cases (none with actual harm):

- `https://claude.ai\@evil.com/` → browser interprets as path per WHATWG → lands on claude.ai
- `http://claude.ai/cb` (HTTP downgrade) → lands on claude.ai
- `ftp://` `gopher://` etc. → browser won't open

### 2.4 CT Log + claude.ai Large-Scale Dictionary Attack

**Attack**: Attacker extracts hosts like `mcp.*` / `*-claude.*` from Certificate Transparency logs and automates connector registration attempts on claude.ai. The nginx ACL `allow 160.79.104.0/21` on `/token` allows the entire Anthropic range, so attacks via claude.ai pass through.

**Assessment**:

- Succeeds if the secret is weak (short secret, dictionary words, copy-pasted sample values)
- Requires scale (attack economics don't work for a niche state)
- If this becomes widespread, claude.ai will likely implement a standard SSH connector (historically, high demand for a feature leads to adoption by others)
- After SSH standardization, new users will use the standard SSH connector, reducing this script's attack surface
- Existing users can continue operating safely with 122-bit tokens derived from randomUUID()

**Defense**:

- Sufficient CLIENT_SECRET strength (12+ random characters; don't use sample values from documentation as-is)
- Sufficient CLIENT_ID strength (6–8 digit number; avoid birthdays, phone numbers, sequential numbers)
- Email notification loop for detection → even if an attack succeeds, it is discovered and discarded per server, making the attack uneconomical

### 2.5 IPv6 ACL Bypass

**Attack**: The nginx ACL for `/token` only has `allow 160.79.104.0/21` for IPv4 CIDR. For IPv6 source addresses, the IPv4 allow rule doesn't match, resulting in `deny all`.

**Assessment**:

- `disable_ipv6 = 1` at the OS level means the kernel doesn't process IPv6 (first defense)
- nginx's 443 listen is IPv4 only (`listen 443 ssl;`, no `listen [::]:443`) (second defense)
- nginx's `allow 160.79.104.0/21; deny all;` rejects IPv6 sources with `deny all` (third defense)
- No DNS AAAA records (clients don't resolve IPv6) (fourth defense)

**No bypass currently occurs.** However, if IPv6 is enabled in future operational changes:

- Adding `listen [::]:443 ssl;` to mcp.conf would cause the ACL to reject legitimate Anthropic IPv6 traffic (availability issue)
- This affects availability rather than attack surface, so it's a safe-side behavior

### 2.6 Race Attack via mail Process Kill

**Attack**: The moment the attacker receives `access_token` from `/token`, they kill the `mail` process or postfix as root and delete the notification email remaining in the local queue.

**Assessment**:

- During the 5-second `setTimeout`, s-nail hands off to postfix → postfix forwards to external relay (Sakura SMTP server) → Sakura SMTP retains in queue
- Measured values: local postfix → external relay: 0.13–0.64 seconds (past logs)
- 5 seconds is sufficient margin for handoff to external relay to complete
- By the time the attacker receives `access_token`, the email is already on the Sakura SMTP server, an unreachable separate host
- Destroying postfix on the server side cannot stop the notification

**Defense is working.**

### 2.7 Detection Evasion via client_id Spoofing

**Attack**: Attacker enters a value similar to the legitimate user's in the `client_id` field, causing the notification email to be mistaken as "my own operation."

**Assessment**:

- CLIENT_ID is **not stored on the server** (the `/token` handler only echoes it back)
- Attacker cannot obtain CLIENT_ID by examining the server
- As long as the legitimate user uses a random 6–8 digit number, the attacker's probability of guessing correctly is 10⁻⁶ to 10⁻⁸
- The constraint of "6–8 digit number" is publicly known, so the attacker's search space is 10⁸ possibilities

**Defense depends on how CLIENT_ID is chosen**:

- Recommended: generate a random 8-digit number with `node -e "console.log(require('crypto').randomInt(10000000, 100000000))"`
- Not recommended:
  - **Today's date** (e.g., `20260524`): The top candidate when attackers try to predict the user's intended value. Attackers aiming for stealth intrusion try date values first since they're "natural-looking" values users might pick
  - Birthdays (8 digits, guessable)
  - Last 8 digits of phone number (in attack dictionaries)
  - Sequential numbers (`12345678`), repeating digits (`88888888`)
  - Values used in previous server builds (history leakage risk)

### 2.8 Token Acquisition via Configuration/Hash Leakage

**Attack**: CLIENT_SECRET remains in plaintext at `/root/.sakuravps/<host>.sh` after startup script template expansion. Also, a sha256 hash of the token is stored in `/etc/mcp-server/hash`. If these leak through some channel, can an access_token be obtained?

**Assessment**: **The access_token itself does not leak through either path.**

- **Plaintext CLIENT_SECRET in script**: The token is dynamically generated with `randomUUID()` at setup time and is not in the script. Even if CLIENT_SECRET leaks, re-issuance is impossible if `/token` has already been consumed (secret file already deleted). Unless running a re-issuance operation, CLIENT_SECRET alone cannot obtain an access_token
- **`/etc/mcp-server/hash`**: It's a sha256 hash, so reversing the token is practically impossible (2^256 possibilities). Even with the hash, authentication cannot pass (`/mcp/sse` compares `sha256(presented token)` with the hash, so the token itself is required)
- **If the VPS is compromised**: The attacker already has root access, so they can write back a new secret/token and issue any value as access_token. This is a post-compromise scenario, separate from "token acquisition via leakage"

**No current actual harm.** The plaintext CLIENT_SECRET in the script can be avoided by generating a new value at re-setup (operational practice of not reusing old values).

### 2.9 Host Header Injection in Metadata Endpoint

**Attack**: `/.well-known/oauth-authorization-server` constructs `issuer` / `authorization_endpoint` / `token_endpoint` in its response from `X-Forwarded-Host` / `X-Forwarded-Proto`. If an attacker sends spoofed headers, they could potentially redirect claude.ai to an attacker-controlled endpoint.

**Assessment**:

- In the nginx configuration, `proxy_set_header X-Forwarded-Host $host;` and `proxy_set_header X-Forwarded-Proto $scheme;` are **explicitly set** in the `/.well-known/oauth-authorization-server` location
- nginx's `proxy_set_header` overwrites even if the same header name comes from the client
- → Spoofed headers from the client do not reach the backend

**Defense is working.** Note: if these `proxy_set_header` directives are removed during nginx configuration changes, `req.headers["x-forwarded-host"]` in Express would become client-originated, enabling injection.

## 3. The Nature of CLIENT_ID: A Secret Known Neither to the Server nor the Attacker

In OAuth2 convention, CLIENT_ID is a "public identifier," but in this system it is redefined as a **secret passphrase**.

**Traditional OAuth2 client_id**:

- Identifier pre-registered with the authorization server
- Treated as public information
- Primarily for logging and usage statistics

**client_id in this system**:

- Not pre-registered on the server (not stored in `/etc/mcp-server/`)
- The value the user enters in the Claude.ai connector arrives at the server via the `/token` request
- The server only echoes it back in the email subject
- Information known only to the legitimate user (configurator) and Claude.ai

**Closed-loop self-identification marker**:

```
[User] → Configure → [Claude.ai Connector]
                       ↓ /token { client_id: <X> }
                    [MCP Server] (echoes X without storing)
                       ↓ mail Subject: client_id=<X>
                    [User's Email] ← Received
                       ↓ Visual verification
                    [Legitimate User] (checks if X matches the value they configured)
```

**Unknown to the attacker**:

- Not stored on the server, so CLIENT_ID cannot be obtained by examining the server
- On the network, it's enclosed in HTTPS between Claude.ai → MCP server
- Even an attacker who has broken CLIENT_SECRET must separately guess CLIENT_ID

**Operational guidelines derived from this property**:

- CLIENT_ID needs to be "noted down" (cannot detect intrusion if forgotten)
- CLIENT_ID should "not be saved to a file on the server" (avoids creating a leakage path)
- CLIENT_ID should "not be shown as an example in blog posts or chats" (avoids adding material for dictionary attacks)
- CLIENT_ID should "not be reused across multiple servers" (one server's leak affects all)

## 4. Design Temporality: Relationship with SSH Standard Connector

This script is positioned as a **stopgap until SSH standard connectors become widespread**.

**Underlying industry prediction**:

1. This script becoming widespread = latent demand for "remotely controlling VPS from Claude" becomes apparent
2. If demand becomes apparent, economic incentive for Anthropic or competitors to implement SSH connector as standard arises
3. Competitive pressure (historical pattern of MCP, function calling, vision, computer use, etc.) leads to adoption by others
4. VPS side already has existing mechanisms for SSH public key configuration
5. After standardization, new users will use the standard SSH connector

**"Attack value" and "standardization trigger" both fire on the same event (= widespread adoption)**, so "the phase when large-scale attacks are economically viable" and "when this script is replaced" are nearly synchronized. The attacker's "optimal timing" is evaluated as extremely short or nonexistent.

**Residual risk**: If a 1–2 year gap between widespread adoption and SSH standardization occurs, that period could be targeted by opportunistic attacks. **During this period, the strength of CLIENT_SECRET / CLIENT_ID and the integrity of the email notification loop are critically important.**

## 5. Long-Term Operational Safety for Existing Users

After SSH standard connectors become widespread, existing users can continue operations without any changes.

**Basis for continued safety**:

| Element | Status |
|---|---|
| Bearer token authentication | 122-bit derived from randomUUID(); brute force requires 2^122 ≈ 5×10^36 attempts — practically impossible |
| Token comparison | Constant-time with `crypto.timingSafeEqual` |
| HTTPS certificate | Auto-renewal by certbot (every 90 days) |
| OS packages | Auto-updated by dnf-automatic (security) |
| Kernel | Updates applied via weekly reboot |
| `/token` endpoint | Already consumed secret/token; no attack surface |
| nginx ACL (Anthropic IP) | Applied only to `/token`; `/mcp/sse` has no ACL (protected by token auth) |

**External factors to watch**:

- Anthropic IP range changes: Currently `160.79.104.0/21`, but if Anthropic expands it, the `/token` ACL needs manual update. However, since `/token` is already consumed, this only matters when running a re-issuance operation
- MCP protocol spec changes: SDK version updates could break compatibility. Can be managed with pinned versions in `npm install`
- claude.ai SSE spec changes: Issues like increased connection disconnections may occur

**The base implementation is extremely simple** (Express + SSE + Bearer auth), making it resilient to breaking changes.

## 6. Notes on Script Modification

Notes for those modifying or forking this script.

### 6.1 Changing the Email Sending Path (Slack notifications, etc.)

When replacing `spawn("mail", [...])` with `spawn("curl", [...])` etc., note:

- Notification failure behavior: The current design ignores `mail`'s exit code and returns the token after a 5-second setTimeout. This intentional ignorance is to avoid leaking to the attacker a signal that notification was blocked
- However, as a side effect, after an attacker gains root access, they can disable email sending for subsequent token issuances by replacing `/bin/mail` with a dummy binary (see 2.1 step 5). Restoration triggers include timers, file watchers, detecting own email delivery completion, etc. **This type of attack cannot be detected server-side**, so the unpredictability of the user's `client_id` becomes the last line of defense
- Notification delay: 5 seconds is set as sufficient time for handoff to external SMTP. If using Slack Webhook etc., adjust for the end-to-end latency
- `client_id` sanitization: Sanitize rules need to be changed based on the messaging spec of the notification target (escape `<` `>` `&` for Slack; avoid spam words for email)

### 6.2 Changing the 5-Second Delay

- Shorten (e.g., 1 second): Risk of not completing handoff to external SMTP. If the attacker destroys postfix immediately after receiving the token, there's a higher chance the notification won't arrive
- Lengthen (e.g., 30 seconds): Risk of conflicting with the claude.ai side timeout (usually 30–60 seconds)

The design value of 5 seconds was determined as "time needed for external SMTP handoff (measured: 0.13–0.64 seconds) + safety margin."

### 6.3 IP ACL Range Update

If Anthropic expands or changes the IP range in the future:

```nginx
# /etc/nginx/conf.d/mcp.conf
location /token {
    allow 160.79.104.0/21;       # existing
    allow <new range>;            # add
    deny all;
    proxy_pass http://127.0.0.1:3000/token;
}
```

Check the latest IP range at https://platform.claude.com/docs/en/api/ip-addresses.

### 6.4 Changing client_id Sanitization

The `+v` + `!cid` check ensures both "only digits accepted" and "token issuance also stops on throw path." If relaxing this:

- Accepting strings → spam filter risk returns
- Going through `String()` → throw path with `{toString: 1}` returns, but since token is not issued on throw path, it's acceptable from a requirements perspective

To absorb `String()` throws, pre-checking with `typeof q.body.client_id === "string"` is safest.

### 6.5 exec_command Timeout Change

Currently 30 seconds. Needs to be extended for long-running tasks (`apt upgrade`, etc.). However, since responses won't return if they exceed the claude.ai SSE timeout (approximately 60 seconds), running with `nohup ... &` in the background is recommended.

## 7. Troubleshooting: Log Locations

Logs to check when something seems wrong.

| Log | Path | Contents |
|---|---|---|
| MCP setup log | `/var/log/mcp-startup.log` | Build log from initial startup |
| MCP server log | `/var/log/mcp-server.log` | Node.js stdout/stderr |
| MCP systemd log | `journalctl -u mcp-server` | Service restarts and crashes |
| nginx access | `/var/log/nginx/access.log` | (MCP paths have access_log off, so only /token etc.) |
| nginx error | `/var/log/nginx/error.log` | Proxy errors and SSL issues |
| postfix | `journalctl -u postfix` | Email send success/failure and queue state |
| postfix queue | `mailq` | Emails awaiting delivery |
| fail2ban | `journalctl -u fail2ban` | SSH brute-force detection and ban records |
| Authentication (sshd etc.) | `journalctl _COMM=sshd` | SSH login history |
| BIND | `journalctl -u named` | DNS queries and zone transfers |
| certbot | `/var/log/letsencrypt/letsencrypt.log` | Certificate acquisition and renewal |

**What to check first when anomaly is detected**:

1. Check `/var/log/nginx/access.log` for source IP and timestamp of connections to `/token`
2. Check `journalctl -u postfix` for email send success/failure
3. Check `/var/log/mcp-server.log` for /token handler execution records (currently no log output; add if needed)
4. Check `ls -la /etc/mcp-server/` for state of secret/token/hash files

## 8. Responding to Anthropic IP Range Updates

The nginx ACL for `/token` depends on the claude.ai API IP range.

**Current**: `160.79.104.0/21`

**How to check**:

1. Periodically check https://platform.claude.com/docs/en/api/ip-addresses (about once a year)
2. If the claude.ai connector suddenly starts getting 403 responses from `/token`, suspect an IP range change

**Update procedure**:

```bash
# Edit nginx configuration
vi /etc/nginx/conf.d/mcp.conf
# Update the allow line inside location /token { ... }

# Test configuration
nginx -t

# Reload (use the nginx_reload tool if accessing via MCP)
systemctl reload nginx
```

**Scenarios requiring update**:

- Does not affect the already-consumed `/token` (exchanged only once at setup time)
- Needed for new setups or when running `/token` re-issuance operations
- Does not affect existing users continuing to operate via `/mcp/sse` (separate location with no ACL)

## 9. Token Re-issuance and Reset Operations

> **Warning**: If the following operations fail, MCP connections may become impossible and OS reinstallation with data initialization may be required. Please use only after fully understanding the contents.
>
> In particular, the state of secret/token/hash in `/etc/mcp-server/` is tightly coupled to the `/token` handler behavior. Entering an inconsistent state (e.g., secret recreated but token placed that doesn't match hash) will result in 403 for all subsequent `/token` requests, and `/mcp/sse` will also return 401 for authentication failure. Without an SSH public key configured, the only recovery option is OS reinstallation.

### 9.1 Path A: MCP-Based Bootstrapping (No SSH Required, Consistent with Design)

Procedure for installing a new secret/token from an existing MCP connection with one Claude.ai account, to connect a second or subsequent account. **Assumes your Claude.ai connector is already working.**

```
1. From the existing MCP connection, install new secret/token via exec_command:

   NEW_SECRET="<CLIENT_SECRET for 2nd account>"
   NEW_TOKEN=$(node -e "console.log(require('crypto').randomUUID())")
   echo "$NEW_SECRET" > /etc/mcp-server/secret
   echo "$NEW_TOKEN" > /etc/mcp-server/token
   chmod 600 /etc/mcp-server/secret /etc/mcp-server/token

2. Register the 2nd Claude.ai connector (new 6–8 digit number for client_id):

   URL:           https://<DOMAIN>/mcp/sse
   client_id:     <number for 2nd account>
   client_secret: <value set as NEW_SECRET>

3. When the 2nd account connects, $NEW_TOKEN is issued as access_token,
   and the hash is overwritten. The existing (1st) token is invalidated.

4. To reconnect the 1st account, repeat the same procedure for the 1st account.
   Utilizing this "each connection invalidates the other" property effectively
   creates an "on-demand authentication" operation.
```

Since `exec_command` itself is a root shell, this path functions as an SSH alternative, with the advantage of not needing to share SSH private keys.

### 9.2 Path B: Token Sharing via Attack Scenario

By intentionally following the steps of attack scenario 2.1 "stealth intrusion," legitimate users can build an MCP server where **multiple Claude.ai accounts share the same token**.

```
1. Via Path A, install secret and any token value before the first connection
2. 1st Claude.ai account connects → the installed token is issued as access_token
3. From the 1st account's MCP, reinstall the same secret/token (self re-issuance)
   echo "<same CLIENT_SECRET>" > /etc/mcp-server/secret
   echo "<same token value>" > /etc/mcp-server/token
   chmod 600 /etc/mcp-server/secret /etc/mcp-server/token
4. 2nd Claude.ai account connects with the same client_secret
5. Result: both accounts share the same token (same hash; both can connect in parallel)
```

This operation is technically the same as "legitimate user executing a stealth intrusion attack against themselves." It is positioned as the legitimate method for multi-account operation.

### 9.3 Path C: Via SSH (Traditional Method; Available if SSH Key is Configured)

If an SSH public key is configured in the Sakura VPS control panel, you can SSH in and perform the same operations.

```bash
ssh root@<DOMAIN>
NEW_SECRET="<new CLIENT_SECRET>"
NEW_TOKEN=$(node -e "console.log(require('crypto').randomUUID())")
echo "$NEW_SECRET" > /etc/mcp-server/secret
echo "$NEW_TOKEN" > /etc/mcp-server/token
chmod 600 /etc/mcp-server/secret /etc/mcp-server/token
```

### 9.4 Token Reset (Immediate Access Revocation)

```bash
rm /etc/mcp-server/hash
# Returns 401 from the next request onward
# To reconnect, execute the Path A/B/C procedure
```

Since the `hash` file is the basis for authentication, deleting it invalidates all existing Bearer tokens.
