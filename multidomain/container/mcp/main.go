// https://github.com/paijp/vps-mcp
//
// vps-mcp (multidomain edition): MCP server for VPS containers.
//
// Go port of the former Node.js index.mjs; behaviour, endpoints and
// environment variables are unchanged. This port
// uses only the Go standard library: the MCP JSON-RPC protocol (Streamable
// HTTP in stateless mode + legacy SSE) and RS256 JWT verification for GitHub
// Actions OIDC are implemented here directly, so the build needs no module
// downloads and the result is a single static binary.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

var (
	subdomain      = envOr("SUBDOMAIN", "localhost")
	mailDomain     = envOr("MAIL_DOMAIN", subdomain)
	notifyEmail    = os.Getenv("NOTIFY_EMAIL")
	oauthBase      = strings.TrimRight(os.Getenv("OAUTH_BASE"), "/")
	ghClientID     = os.Getenv("GITHUB_CLIENT_ID")
	ghClientSecret = os.Getenv("GITHUB_CLIENT_SECRET")
	deployBaseDir  = filepath.Clean(envOr("DEPLOY_BASE_DIR", "/srv/deploy"))
	deployAudience = envOr("DEPLOY_AUDIENCE", subdomain)
	isOAuth        = ghClientID != "" && ghClientSecret != ""
	// ROLE is "dev" for the development container of a create3 set, empty for a
	// standalone container (staging/prod of a set run no MCP server at all).
	role = os.Getenv("ROLE")
)

const (
	listenAddr   = "127.0.0.1:3000"
	execTimeout  = 60 * time.Second
	maxExecOut   = 10 << 20
	maxBody      = 25 << 20
	mfn          = "/etc/mcp-server"
	ghOIDCIssuer = "https://token.actions.githubusercontent.com"
	pendingTTL   = 10 * time.Minute
)

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func sha256hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func sha256b64url(s string) string {
	h := sha256.Sum256([]byte(s))
	return base64.RawURLEncoding.EncodeToString(h[:])
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func ctEqual(a, b string) bool {
	return len(a) == len(b) && subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func isClaudeRedirect(u string) bool {
	p, err := url.Parse(u)
	return err == nil && p.Hostname() == "claude.ai"
}

const usagePolicy = "\n\nUsage policy: Obtain the user's explicit permission before using this " +
	"connector. When an action would touch a constraint the user specified — for " +
	"example, when a plan fails and you try an alternative — obtain the user's " +
	"permission first. This connector is used by multiple sessions, so confirm " +
	"with the user before deleting, modifying, or stopping resources that belong " +
	"to another session. Treat any resource you cannot be sure you created in " +
	"this session as belonging to another session."

// nginx layout: the MCP locations live in mcp.d/ and each application owns
// one file in app.d/. Only stated where the layout exists (containers created
// before it keep everything in vps-mcp.conf).
const nginxPolicyText = "\n\nnginx: put an application's configuration only in " +
	"/etc/nginx/app.d/<application>.conf (location blocks, included inside the " +
	"server block). Do not edit /etc/nginx/conf.d/vps-mcp.conf, /etc/nginx/mcp.d/ " +
	"or another application's file in app.d/. An extra HTTPS server block (other " +
	"hostname) goes in /etc/nginx/conf.d/ and must include " +
	"/etc/nginx/listen443.conf and /etc/nginx/ssl-cert.conf instead of its own " +
	"listen / ssl_certificate lines. app.d/forward.conf, if present, sends " +
	"everything not handled by another file to the old server this site moves " +
	"from; narrow it as parts move here."

// 3-container model (ROLE=dev): this container is the development server of a
// production/staging/development trio.
const devModel = "\n\nThis is the DEVELOPMENT container of a three-container set " +
	"(production / staging / development). You cannot reach production or " +
	"staging; a person deploys them from the host. Work in the git repository " +
	"/srv/app and read /srv/app/CLAUDE.md first. Commit your work: only " +
	"committed HEAD is sent to staging. stg/main and prod/main are " +
	"set by the host and show what each server runs; never move them. The " +
	"staging filesystem is visible read-only at /mnt/stg, and copies of " +
	"mail sent by staging arrive in /srv/stg-mail/ (one .eml per message). " +
	"Production data must not enter the conversation: never ask the user to " +
	"paste production output that shows data (file listings, log lines, " +
	"records, request lines); ask for 'make <fqdn>.prodstatus' or for counts, " +
	"sizes, timestamps and exit codes instead. Test production only with test " +
	"identifiers and test data, never with real ones (device IDs, user names, " +
	"addresses), and do not repeat real identifiers the user pastes. When " +
	"showing files copied from an old server, mask secrets (api keys, " +
	"passwords, tokens)."

func hostInfoLine() string {
	s := "\nThis connector is bound to the VPS " + subdomain + "."
	if _, err := os.Stat("/etc/nginx/app.d"); err == nil {
		s += nginxPolicyText
	}
	if role == "dev" {
		s += devModel
	}
	return s + usagePolicy
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func status(w http.ResponseWriter, code int) { w.WriteHeader(code) }

// formOrJSON reads a request body as JSON or urlencoded form into a flat map.
func formOrJSON(r *http.Request) map[string]any {
	out := map[string]any{}
	body, _ := io.ReadAll(http.MaxBytesReader(nil, r.Body, maxBody))
	ct := r.Header.Get("Content-Type")
	switch {
	case strings.Contains(ct, "application/json"):
		json.Unmarshal(body, &out)
	case strings.Contains(ct, "application/x-www-form-urlencoded"):
		if v, err := url.ParseQuery(string(body)); err == nil {
			for k := range v {
				out[k] = v.Get(k)
			}
		}
	}
	return out
}

func str(m map[string]any, k string) string {
	if s, ok := m[k].(string); ok {
		return s
	}
	return ""
}

// ── GitHub OIDC verification (for /deploy) ────────────────────────────────────

type jwksCache struct {
	mu      sync.Mutex
	keys    map[string]*rsa.PublicKey
	fetched time.Time
}

var jwks = &jwksCache{}

func (c *jwksCache) get(kid string) (*rsa.PublicKey, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if k, ok := c.keys[kid]; ok && time.Since(c.fetched) < 10*time.Minute {
		return k, nil
	}
	// Refetch on cache expiry or unknown kid (key rotation), at most every 30s.
	if time.Since(c.fetched) > 30*time.Second || c.keys == nil {
		if err := c.refresh(); err != nil && c.keys == nil {
			return nil, err
		}
	}
	if k, ok := c.keys[kid]; ok {
		return k, nil
	}
	return nil, errors.New("unknown kid")
}

func (c *jwksCache) refresh() error {
	cl := &http.Client{Timeout: 10 * time.Second}
	resp, err := cl.Get(ghOIDCIssuer + "/.well-known/jwks")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var set struct {
		Keys []struct{ Kty, Kid, N, E string } `json:"keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&set); err != nil {
		return err
	}
	keys := map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		if k.Kty != "RSA" {
			continue
		}
		nb, err1 := base64.RawURLEncoding.DecodeString(k.N)
		eb, err2 := base64.RawURLEncoding.DecodeString(k.E)
		if err1 != nil || err2 != nil {
			continue
		}
		keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(nb), E: int(new(big.Int).SetBytes(eb).Int64())}
	}
	c.keys, c.fetched = keys, time.Now()
	return nil
}

var (
	usedJtiMu sync.Mutex
	usedJti   = map[string]time.Time{}
)

type deployOwnerT struct {
	ID    string `json:"id"`
	Login string `json:"login"`
}

func deployOwner() *deployOwnerT {
	b, err := os.ReadFile(mfn + "/deploy_owner")
	if err != nil {
		return nil
	}
	var o deployOwnerT
	if json.Unmarshal(b, &o) != nil {
		return nil
	}
	return &o
}

func verifyDeployToken(tok string) error {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return errors.New("malformed")
	}
	hb, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return err
	}
	var hdr struct{ Alg, Kid string }
	if json.Unmarshal(hb, &hdr) != nil || hdr.Alg != "RS256" {
		return errors.New("bad header")
	}
	key, err := jwks.get(hdr.Kid)
	if err != nil {
		return err
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return err
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], sig); err != nil {
		return err
	}
	pb, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return err
	}
	var p map[string]any
	dec := json.NewDecoder(bytes.NewReader(pb))
	dec.UseNumber()
	if dec.Decode(&p) != nil {
		return errors.New("bad payload")
	}
	if p["iss"] != ghOIDCIssuer {
		return errors.New("issuer")
	}
	audOK := false
	switch a := p["aud"].(type) {
	case string:
		audOK = a == deployAudience
	case []any:
		for _, x := range a {
			if x == deployAudience {
				audOK = true
			}
		}
	}
	if !audOK {
		return errors.New("audience")
	}
	now := time.Now().Unix()
	num := func(k string) (int64, bool) {
		n, ok := p[k].(json.Number)
		if !ok {
			return 0, false
		}
		f, err := n.Float64()
		return int64(f), err == nil
	}
	exp, ok := num("exp")
	if !ok || exp <= now {
		return errors.New("expired")
	}
	if nbf, ok := num("nbf"); ok && nbf > now {
		return errors.New("not yet valid")
	}
	owner := deployOwner()
	if owner == nil || owner.ID == "" {
		return errors.New("deploy owner not bound")
	}
	if fmt.Sprint(p["repository_owner_id"]) != owner.ID {
		return errors.New("owner mismatch")
	}
	if jti, ok := p["jti"].(string); ok && jti != "" {
		usedJtiMu.Lock()
		defer usedJtiMu.Unlock()
		if _, used := usedJti[jti]; used {
			return errors.New("replay")
		}
		usedJti[jti] = time.Unix(exp, 0)
	}
	return nil
}

func resolveDeployPath(rel string) (string, bool) {
	dest := filepath.Join(deployBaseDir, rel)
	if dest != deployBaseDir && !strings.HasPrefix(dest, deployBaseDir+string(os.PathSeparator)) {
		return "", false
	}
	return dest, true
}

func handleDeploy(w http.ResponseWriter, r *http.Request) {
	auth := r.Header.Get("Authorization")
	if len(auth) < 8 || !strings.EqualFold(auth[:7], "bearer ") {
		status(w, 401)
		return
	}
	if err := verifyDeployToken(strings.TrimSpace(auth[7:])); err != nil {
		status(w, 401)
		return
	}
	dest, ok := resolveDeployPath(strings.TrimPrefix(r.URL.Path, "/mcp/messages/deploy/"))
	if !ok {
		status(w, 400)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		status(w, 413)
		return
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o777); err == nil {
		err = os.WriteFile(dest, body, 0o666)
		if err == nil {
			w.Write([]byte("ok"))
			return
		}
		http.Error(w, err.Error(), 500)
		return
	} else {
		http.Error(w, err.Error(), 500)
	}
}

// ── OAuth endpoints ───────────────────────────────────────────────────────────

func handleDiscovery(w http.ResponseWriter, r *http.Request) {
	host := r.Header.Get("X-Forwarded-Host")
	if host == "" {
		host = r.Host
	}
	proto := r.Header.Get("X-Forwarded-Proto")
	if proto == "" {
		proto = "http"
	}
	base := proto + "://" + host
	writeJSON(w, 200, map[string]any{
		"issuer":                                base,
		"authorization_endpoint":                base + "/mcp/authorize",
		"token_endpoint":                        base + "/mcp/token",
		"registration_endpoint":                 base + "/mcp/register",
		"token_endpoint_auth_methods_supported": []string{"none"},
		"response_types_supported":              []string{"code"},
		"code_challenge_methods_supported":      []string{"S256"},
	})
}

func handleRegister(w http.ResponseWriter, r *http.Request) {
	meta := formOrJSON(r)
	out := map[string]any{
		"client_id":                  randHex(16),
		"client_id_issued_at":        time.Now().Unix(),
		"redirect_uris":              []any{},
		"token_endpoint_auth_method": "none",
		"grant_types":                []string{"authorization_code"},
		"response_types":             []string{"code"},
	}
	if v, ok := meta["redirect_uris"].([]any); ok {
		out["redirect_uris"] = v
	}
	for _, k := range []string{"grant_types", "response_types", "client_name", "scope"} {
		if v, ok := meta[k]; ok && v != nil && v != "" {
			out[k] = v
		}
	}
	writeJSON(w, 201, out)
}

func handleAuthorize(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	redirect := q.Get("redirect_uri")
	if !isClaudeRedirect(redirect) || q.Get("code_challenge_method") != "S256" || q.Get("code_challenge") == "" {
		status(w, 400)
		return
	}
	if oauthBase == "" {
		status(w, 500)
		return
	}
	v := url.Values{}
	v.Set("claude_redirect", redirect)
	if s := q.Get("state"); s != "" {
		v.Set("claude_state", s)
	}
	v.Set("challenge", q.Get("code_challenge"))
	http.Redirect(w, r, oauthBase+"/mcp/start?"+v.Encode(), 302)
}

func handleToken(w http.ResponseWriter, r *http.Request) {
	body := formOrJSON(r)
	if oauthBase == "" {
		status(w, 500)
		return
	}
	reqBody, _ := json.Marshal(map[string]any{"code": body["code"], "code_verifier": body["code_verifier"]})
	cl := &http.Client{Timeout: 15 * time.Second}
	resp, err := cl.Post(oauthBase+"/mcp/resolve", "application/json", bytes.NewReader(reqBody))
	if err != nil {
		status(w, 502)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		status(w, 403)
		return
	}
	var resolved map[string]any
	if json.NewDecoder(resp.Body).Decode(&resolved) != nil {
		status(w, 502)
		return
	}
	email := str(resolved, "email")
	if email == "" || !strings.EqualFold(email, notifyEmail) {
		status(w, 403)
		return
	}

	token := randHex(32)
	if b, err := os.ReadFile(mfn + "/token"); err == nil {
		if t := strings.TrimSpace(string(b)); len(t) >= 32 {
			token = t
		}
	}
	if err := os.WriteFile(mfn+"/hash", []byte(sha256hex(token)), 0o600); err != nil {
		status(w, 500)
		return
	}

	if !isOAuth {
		if id := fmt.Sprint(resolved["owner_id"]); resolved["owner_id"] != nil && id != "" {
			b, _ := json.Marshal(deployOwnerT{ID: id, Login: str(resolved, "owner_login")})
			os.WriteFile(mfn+"/deploy_owner", b, 0o600)
		}
	}

	if notifyEmail != "" {
		go func() {
			cmd := exec.Command("/usr/sbin/sendmail", "-f", "noreply@"+mailDomain, notifyEmail)
			cmd.Stdin = strings.NewReader("From: noreply@" + mailDomain + "\r\nTo: " + notifyEmail +
				"\r\nSubject: MCP token issued\r\n\r\nA Bearer token was issued after GitHub login as " + email + ".\r\n")
			if err := cmd.Run(); err != nil {
				log.Printf("sendmail: %v", err)
			}
		}()
	}
	writeJSON(w, 200, map[string]any{"access_token": token, "token_type": "Bearer"})
}

// ── OAuth-container endpoints (GitHub login broker) ───────────────────────────

type pendingEntry struct {
	challenge, email, ghID, ghLogin string
	created                         time.Time
}

var (
	pendingMu sync.Mutex
	pending   = map[string]pendingEntry{}
)

type ghState struct {
	ClaudeRedirect string `json:"claude_redirect"`
	ClaudeState    string `json:"claude_state"`
	Challenge      string `json:"challenge"`
}

func handleStart(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	st := ghState{q.Get("claude_redirect"), q.Get("claude_state"), q.Get("challenge")}
	if !isClaudeRedirect(st.ClaudeRedirect) || st.Challenge == "" {
		status(w, 400)
		return
	}
	sb, _ := json.Marshal(st)
	v := url.Values{}
	v.Set("client_id", ghClientID)
	v.Set("redirect_uri", oauthBase+"/mcp/callback")
	v.Set("scope", "user:email")
	v.Set("state", base64.RawURLEncoding.EncodeToString(sb))
	http.Redirect(w, r, "https://github.com/login/oauth/authorize?"+v.Encode(), 302)
}

func ghGet(cl *http.Client, u, tok string, out any) error {
	req, _ := http.NewRequest("GET", u, nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "vps-mcp")
	resp, err := cl.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return json.NewDecoder(resp.Body).Decode(out)
}

func handleCallback(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var st ghState
	sb, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(q.Get("state"), "="))
	if err != nil || json.Unmarshal(sb, &st) != nil {
		status(w, 400)
		return
	}
	code := q.Get("code")
	if !isClaudeRedirect(st.ClaudeRedirect) || st.Challenge == "" || code == "" {
		status(w, 400)
		return
	}
	cl := &http.Client{Timeout: 15 * time.Second}
	reqBody, _ := json.Marshal(map[string]string{
		"client_id": ghClientID, "client_secret": ghClientSecret,
		"code": code, "redirect_uri": oauthBase + "/mcp/callback",
	})
	req, _ := http.NewRequest("POST", "https://github.com/login/oauth/access_token", bytes.NewReader(reqBody))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := cl.Do(req)
	if err != nil {
		status(w, 502)
		return
	}
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	err = json.NewDecoder(resp.Body).Decode(&tok)
	resp.Body.Close()
	if err != nil {
		status(w, 502)
		return
	}
	if tok.AccessToken == "" {
		status(w, 403)
		return
	}
	var emails []struct {
		Email             string
		Primary, Verified bool
	}
	if err := ghGet(cl, "https://api.github.com/user/emails", tok.AccessToken, &emails); err != nil {
		status(w, 403)
		return
	}
	primary := ""
	for _, e := range emails {
		if e.Primary && e.Verified {
			primary = e.Email
			break
		}
	}
	if primary == "" {
		status(w, 403)
		return
	}
	var u struct {
		ID    json.Number `json:"id"`
		Login string      `json:"login"`
	}
	ghGet(cl, "https://api.github.com/user", tok.AccessToken, &u) // non-fatal

	authCode := randHex(32)
	pendingMu.Lock()
	pending[authCode] = pendingEntry{st.Challenge, primary, u.ID.String(), u.Login, time.Now()}
	pendingMu.Unlock()

	ru, _ := url.Parse(st.ClaudeRedirect)
	v := ru.Query()
	v.Set("code", authCode)
	if st.ClaudeState != "" {
		v.Set("state", st.ClaudeState)
	}
	ru.RawQuery = v.Encode()
	w.Header().Set("Referrer-Policy", "no-referrer")
	http.Redirect(w, r, ru.String(), 302)
}

func handleResolve(w http.ResponseWriter, r *http.Request) {
	b := formOrJSON(r)
	code, verifier := str(b, "code"), str(b, "code_verifier")
	if code == "" || verifier == "" {
		status(w, 400)
		return
	}
	pendingMu.Lock()
	defer pendingMu.Unlock()
	e, ok := pending[code]
	if !ok {
		status(w, 404)
		return
	}
	if !ctEqual(sha256b64url(verifier), e.challenge) {
		status(w, 403)
		return
	}
	delete(pending, code)
	writeJSON(w, 200, map[string]any{"email": e.email, "owner_id": e.ghID, "owner_login": e.ghLogin})
}

// ── Bearer auth ───────────────────────────────────────────────────────────────

func requireAuth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		t := r.Header.Get("Authorization")
		if len(t) >= 7 && strings.EqualFold(t[:7], "bearer ") {
			t = strings.TrimLeft(t[7:], " \t")
		}
		hb, err := os.ReadFile(mfn + "/hash")
		if err != nil || !ctEqual(strings.TrimSpace(string(hb)), sha256hex(t)) {
			status(w, 401)
			return
		}
		h(w, r)
	}
}

// ── Tools ─────────────────────────────────────────────────────────────────────

type tool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
	run         func(args map[string]any) (string, bool)
}

func schema(required []string, props map[string]string) map[string]any {
	p := map[string]any{}
	for k, d := range props {
		p[k] = map[string]any{"type": "string", "description": d}
	}
	s := map[string]any{"type": "object", "properties": p, "additionalProperties": false,
		"$schema": "http://json-schema.org/draft-07/schema#"}
	if len(required) > 0 {
		s["required"] = required
	}
	return s
}

// limitedBuf errors out once more than maxExecOut bytes are written, like
// Node's execFile maxBuffer.
type limitedBuf struct {
	bytes.Buffer
	over bool
}

func (b *limitedBuf) Write(p []byte) (int, error) {
	if b.Len()+len(p) > maxExecOut {
		b.over = true
		return 0, errors.New("maxBuffer exceeded")
	}
	return b.Buffer.Write(p)
}

func execCommand(args map[string]any) (string, bool) {
	command := str(args, "command")
	ctx, cancel := context.WithTimeout(context.Background(), execTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/bash", "-c", command)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }
	cmd.WaitDelay = 5 * time.Second
	var so, se limitedBuf
	cmd.Stdout, cmd.Stderr = &so, &se
	err := cmd.Run()
	out := so.String()
	if se.Len() > 0 {
		out += "\n[stderr]\n" + se.String()
	}
	if err == nil {
		return out, false
	}
	if so.Len() == 0 {
		msg := "Command failed: /bin/bash -c " + command
		if ctx.Err() != nil {
			msg += "\n(timed out after 60s)"
		} else if so.over || se.over {
			msg += "\n(output exceeded 10MB)"
		}
		if se.Len() > 0 {
			msg += "\n" + se.String()
		}
		out = msg
	}
	return "[error]\n" + out, true
}

func readFileTool(args map[string]any) (string, bool) {
	b, err := os.ReadFile(str(args, "path"))
	if err != nil {
		return "[error] " + err.Error(), true
	}
	return string(b), false
}

func writeFileTool(args map[string]any) (string, bool) {
	p := str(args, "path")
	if err := os.MkdirAll(filepath.Dir(p), 0o777); err != nil {
		return "[error] " + err.Error(), true
	}
	if err := os.WriteFile(p, []byte(str(args, "content")), 0o666); err != nil {
		return "[error] " + err.Error(), true
	}
	return "ok", false
}

func nginxReload(map[string]any) (string, bool) {
	var se bytes.Buffer
	cmd := exec.Command("/usr/sbin/nginx", "-t")
	cmd.Stderr = &se
	if err := cmd.Run(); err != nil {
		msg := se.String()
		if msg == "" {
			msg = err.Error()
		}
		return "[error] nginx config test failed:\n" + msg, true
	}
	time.AfterFunc(time.Second, func() {
		if out, err := exec.Command("/usr/bin/systemctl", "reload", "nginx").CombinedOutput(); err != nil {
			log.Printf("nginx_reload: reload failed: %s %v", out, err)
		}
	})
	return "nginx config valid; reload scheduled\n" + se.String(), false
}

func deploySetup(args map[string]any) (string, bool) {
	owner := deployOwner()
	src, dest, build := str(args, "src_dir"), str(args, "dest_prefix"), str(args, "build_workflow")
	if src == "" {
		src = "dist"
	}
	if dest == "" {
		dest = "site"
	}
	var trigger []string
	if build != "" {
		trigger = []string{
			"on:",
			"  # Runs after the build workflow finishes. workflow_run is required",
			"  # because a push made by another workflow's GITHUB_TOKEN does NOT",
			"  # trigger push-based workflows. (Note: workflow_run runs in the",
			"  # default-branch context — checkout the right ref or download the",
			"  # build's artifacts as needed.)",
			"  workflow_run:",
			"    workflows: [\"" + build + "\"]",
			"    types: [completed]",
		}
	} else {
		trigger = []string{
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
		}
	}
	lines := append([]string{"name: deploy-to-vps"}, trigger...)
	lines = append(lines,
		"",
		"permissions:",
		"  id-token: write          # required to mint the OIDC token",
		"  contents: read",
		"",
		"env:",
		"  VPS_HOST: "+deployAudience+"      # this host (OIDC audience)",
		"  SRC_DIR: "+src,
		"  DEST_PREFIX: "+dest+"        # files land under <deploy dir>/<DEST_PREFIX>/",
		"",
		"jobs:",
		"  deploy:",
		"    runs-on: ubuntu-latest",
		"    steps:",
		"      - uses: actions/checkout@v4",
		"",
		"      - name: PUT files to VPS /deploy",
		"        run: |",
		"          set -euo pipefail",
		"          cd \"$SRC_DIR\"",
		"          mapfile -t files < <(find . -type f | sed 's|^\\./||' | sort)",
		"          for rel in \"${files[@]}\"; do",
		"            # The receiver accepts each OIDC token's jti only ONCE (replay",
		"            # protection), so a single token cannot cover several files:",
		"            # mint a fresh one per file.",
		"            token=$(curl -sS \\",
		"              -H \"Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN\" \\",
		"              \"$ACTIONS_ID_TOKEN_REQUEST_URL&audience=${VPS_HOST}\" | jq -r '.value')",
		"            echo \"::add-mask::$token\"",
		"            echo \"PUT $rel\"",
		"            code=$(curl -sS -o /dev/null -w '%{http_code}' \\",
		"              -X PUT --data-binary @\"$rel\" \\",
		"              -H \"Authorization: Bearer $token\" \\",
		"              -H 'Content-Type: application/octet-stream' \\",
		"              \"https://${VPS_HOST}/mcp/messages/deploy/${DEST_PREFIX}/${rel}\")",
		"            test \"$code\" = \"200\" || { echo \"failed: $rel -> HTTP $code\"; exit 1; }",
		"          done",
	)
	yaml := strings.Join(lines, "\n")

	var ownerLine string
	if owner != nil && owner.ID != "" {
		login := owner.Login
		if login == "" {
			login = "?"
		}
		ownerLine = "Deploy owner bound to GitHub @" + login + " (id " + owner.ID + "); " +
			"OIDC tokens from any repo under this account are accepted."
	} else {
		ownerLine = "WARNING: no deploy owner is bound yet. Complete a GitHub login through " +
			"the connector first, then re-run deploy_setup."
	}
	var triggerNote string
	if build != "" {
		triggerNote = "Triggered on completion of the \"" + build + "\" workflow (workflow_run)."
	} else {
		triggerNote = "Triggered on a human push to " + src + "/. IMPORTANT: a push made by another " +
			"workflow using the default GITHUB_TOKEN will NOT trigger this (GitHub blocks " +
			"workflow chaining) — if " + src + "/ is written by a build workflow, either add " +
			"these deploy steps to that workflow, or re-run deploy_setup with " +
			"build_workflow set to use the workflow_run trigger."
	}
	return ownerLine + "\n\n" +
		"Commit the YAML below to .github/workflows/deploy.yml in a repository owned " +
		"by that account. Files in " + src + "/ are uploaded to " +
		"https://" + deployAudience + "/mcp/messages/deploy/" + dest + "/<path> (server dir " +
		deployBaseDir + "/" + dest + "/). No secret is stored — auth is the GitHub OIDC token.\n\n" +
		triggerNote + "\n\n" +
		"```yaml\n" + yaml + "\n```\n", false
}

var tools []tool
var toolByName = map[string]*tool{}

func initTools() {
	tools = []tool{
		{Name: "exec_command",
			Description: "Execute a shell command on the VPS. Returns stdout and stderr." + hostInfoLine(),
			InputSchema: schema([]string{"command"}, map[string]string{"command": "Shell command to run"}),
			run:         execCommand},
		{Name: "read_file",
			Description: "Read a file from the VPS filesystem." + hostInfoLine(),
			InputSchema: schema([]string{"path"}, map[string]string{"path": "Absolute path to the file"}),
			run:         readFileTool},
		{Name: "write_file",
			Description: "Write content to a file on the VPS filesystem. " +
				"If the same content will also live in a GitHub repository, prefer " +
				"committing to GitHub and deploying via GitHub Actions unless the user " +
				"asks otherwise — writing large files directly through this tool costs " +
				"more tokens, takes longer, and fails more often." + hostInfoLine(),
			InputSchema: schema([]string{"path", "content"}, map[string]string{
				"path": "Absolute path to the file", "content": "Content to write"}),
			run: writeFileTool},
		{Name: "nginx_reload",
			Description: "Reload the nginx configuration. Always use this instead of running " +
				"'nginx -s reload' / 'systemctl reload nginx' via exec_command: the MCP " +
				"SSE connection is proxied through nginx, so a synchronous reload can " +
				"interrupt it before the tool result is delivered and stall the client " +
				"until timeout. This validates the config, returns immediately, then " +
				"defers the actual reload so the result is flushed first." + hostInfoLine(),
			InputSchema: schema(nil, map[string]string{}),
			run:         nginxReload},
	}
	if !isOAuth {
		tools = append(tools, tool{Name: "deploy_setup",
			Description: "Generate a ready-to-commit GitHub Actions workflow that deploys files from " +
				"a repository to this host (" + subdomain + ") over HTTPS using GitHub OIDC (no stored secret). " +
				"Files are PUT to /deploy and land under the host's deploy directory. " +
				"Commit the returned YAML to .github/workflows/deploy.yml in a repository " +
				"owned by the GitHub account that logged in here. Deploys are accepted from " +
				"any branch or event in that account (only the owner is checked)." + hostInfoLine(),
			InputSchema: schema(nil, map[string]string{
				"src_dir":     "Directory in the repo to upload (default: dist)",
				"dest_prefix": "Path prefix under the deploy dir (default: site)",
				"build_workflow": "Name of a build workflow that produces the files. If set, the deploy " +
					"triggers on that workflow's completion (workflow_run) instead of push — " +
					"needed because a push made by another workflow's GITHUB_TOKEN does not " +
					"trigger push-based workflows.",
			}),
			run: deploySetup})
	}
	for i := range tools {
		toolByName[tools[i].Name] = &tools[i]
	}
}

// ── MCP JSON-RPC ──────────────────────────────────────────────────────────────

var supportedVersions = []string{"2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"}

type rpcMsg struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcErr struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type rpcResp struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcErr         `json:"error,omitempty"`
}

// handleRPC processes one message; returns nil for notifications/responses.
func handleRPC(m rpcMsg) *rpcResp {
	if m.Method == "" || len(m.ID) == 0 || string(m.ID) == "null" {
		return nil
	}
	resp := &rpcResp{JSONRPC: "2.0", ID: m.ID}
	switch m.Method {
	case "initialize":
		var p struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		json.Unmarshal(m.Params, &p)
		v := supportedVersions[0]
		for _, s := range supportedVersions {
			if s == p.ProtocolVersion {
				v = s
			}
		}
		resp.Result = map[string]any{
			"protocolVersion": v,
			"capabilities":    map[string]any{"tools": map[string]any{"listChanged": true}},
			"serverInfo":      map[string]any{"name": "vps-mcp", "version": "1.0.0"},
		}
	case "ping":
		resp.Result = map[string]any{}
	case "tools/list":
		resp.Result = map[string]any{"tools": tools}
	case "tools/call":
		var p struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		}
		if json.Unmarshal(m.Params, &p) != nil {
			resp.Error = &rpcErr{-32602, "Invalid params"}
			break
		}
		t, ok := toolByName[p.Name]
		if !ok {
			resp.Error = &rpcErr{-32602, "Tool " + p.Name + " not found"}
			break
		}
		if p.Arguments == nil {
			p.Arguments = map[string]any{}
		}
		if req, _ := t.InputSchema["required"].([]string); req != nil {
			for _, k := range req {
				if _, ok := p.Arguments[k].(string); !ok {
					resp.Error = &rpcErr{-32602, "Invalid arguments for tool " + p.Name + ": " + k + " must be a string"}
					return resp
				}
			}
		}
		text, isErr := t.run(p.Arguments)
		r := map[string]any{"content": []map[string]any{{"type": "text", "text": text}}}
		if isErr {
			r["isError"] = true
		}
		resp.Result = r
	case "resources/list":
		resp.Result = map[string]any{"resources": []any{}}
	case "prompts/list":
		resp.Result = map[string]any{"prompts": []any{}}
	default:
		resp.Error = &rpcErr{-32601, "Method not found"}
	}
	return resp
}

// parseMessages accepts a single message or a batch.
func parseMessages(body []byte) ([]rpcMsg, bool, error) {
	body = bytes.TrimSpace(body)
	if len(body) > 0 && body[0] == '[' {
		var ms []rpcMsg
		err := json.Unmarshal(body, &ms)
		return ms, true, err
	}
	var m rpcMsg
	err := json.Unmarshal(body, &m)
	return []rpcMsg{m}, false, err
}

// Streamable HTTP, stateless: one request → JSON response.
func handleStreamable(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		writeJSON(w, 413, rpcResp{JSONRPC: "2.0", ID: json.RawMessage("null"), Error: &rpcErr{-32600, "Request too large"}})
		return
	}
	msgs, batch, err := parseMessages(body)
	if err != nil {
		writeJSON(w, 400, rpcResp{JSONRPC: "2.0", ID: json.RawMessage("null"), Error: &rpcErr{-32700, "Parse error"}})
		return
	}
	var out []*rpcResp
	for _, m := range msgs {
		if res := handleRPC(m); res != nil {
			out = append(out, res)
		}
	}
	if len(out) == 0 {
		status(w, 202)
		return
	}
	if batch {
		writeJSON(w, 200, out)
	} else {
		writeJSON(w, 200, out[0])
	}
}

// Legacy SSE transport.
type sseSession struct {
	ch   chan []byte
	done chan struct{}
}

var (
	sessMu   sync.Mutex
	sessions = map[string]*sseSession{}
)

func handleSSE(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		status(w, 500)
		return
	}
	id := newUUID()
	s := &sseSession{ch: make(chan []byte, 64), done: make(chan struct{})}
	sessMu.Lock()
	sessions[id] = s
	sessMu.Unlock()
	defer func() {
		sessMu.Lock()
		delete(sessions, id)
		sessMu.Unlock()
		close(s.done)
	}()

	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache, no-transform")
	h.Set("Connection", "keep-alive")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(200)
	bw := bufio.NewWriter(w)
	fmt.Fprintf(bw, "event: endpoint\ndata: /mcp/messages?sessionId=%s\n\n", id)
	bw.Flush()
	fl.Flush()

	rc := http.NewResponseController(w)
	ping := time.NewTicker(30 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case msg := <-s.ch:
			rc.SetWriteDeadline(time.Now().Add(30 * time.Second))
			fmt.Fprintf(bw, "event: message\ndata: %s\n\n", msg)
			if bw.Flush() != nil {
				return
			}
			fl.Flush()
		case <-ping.C:
			// SSE comment keeps idle proxies from closing the stream.
			if _, err := bw.WriteString(": ping\n\n"); err != nil || bw.Flush() != nil {
				return
			}
			fl.Flush()
		}
	}
}

func handleMessages(w http.ResponseWriter, r *http.Request) {
	sessMu.Lock()
	s := sessions[r.URL.Query().Get("sessionId")]
	sessMu.Unlock()
	if s == nil {
		writeJSON(w, 404, map[string]string{"error": "session not found"})
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		status(w, 413)
		return
	}
	msgs, _, err := parseMessages(body)
	if err != nil {
		http.Error(w, "Invalid message", 400)
		return
	}
	w.WriteHeader(202)
	w.Write([]byte("Accepted"))
	// Tool calls may run for up to a minute; answer on the SSE stream later.
	for _, m := range msgs {
		go func(m rpcMsg) {
			res := handleRPC(m)
			if res == nil {
				return
			}
			b, _ := json.Marshal(res)
			select {
			case s.ch <- b:
			case <-s.done:
			}
		}(m)
	}
}

func newUUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// ── Main ──────────────────────────────────────────────────────────────────────

func sweeper() {
	for range time.Tick(time.Minute) {
		now := time.Now()
		usedJtiMu.Lock()
		for k, exp := range usedJti {
			if !exp.After(now) {
				delete(usedJti, k)
			}
		}
		usedJtiMu.Unlock()
		pendingMu.Lock()
		for k, v := range pending {
			if now.Sub(v.created) > pendingTTL {
				delete(pending, k)
			}
		}
		pendingMu.Unlock()
	}
}

func main() {
	initTools()
	go sweeper()

	mux := http.NewServeMux()
	if !isOAuth {
		mux.HandleFunc("PUT /mcp/messages/deploy/", handleDeploy)
	}
	mux.HandleFunc("GET /.well-known/oauth-authorization-server", handleDiscovery)
	mux.HandleFunc("POST /mcp/register", handleRegister)
	mux.HandleFunc("GET /mcp/authorize", handleAuthorize)
	mux.HandleFunc("POST /mcp/token", handleToken)
	if isOAuth {
		mux.HandleFunc("GET /mcp/start", handleStart)
		mux.HandleFunc("GET /mcp/callback", handleCallback)
		mux.HandleFunc("POST /mcp/resolve", handleResolve)
	}
	mux.HandleFunc("POST /mcp/sse", requireAuth(handleStreamable))
	mux.HandleFunc("GET /mcp/sse", requireAuth(handleSSE))
	mux.HandleFunc("POST /mcp/messages", requireAuth(handleMessages))

	srv := &http.Server{Addr: listenAddr, Handler: mux, ReadHeaderTimeout: 30 * time.Second}
	log.Printf("vps-mcp listening on %s (subdomain=%s, oauth=%v)", listenAddr, subdomain, isOAuth)
	log.Fatal(srv.ListenAndServe())
}
