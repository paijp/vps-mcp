// https://github.com/paijp/vps-subdomain-mcp

// Package mapping converts hostnames to Podman container names.
//
// The multidomain edition names each container after its full hostname:
//
//	"test.example.com" → "test.example.com-web"
//	"example.com"      → "example.com-web"
//
// A hostname is accepted only when it is a registered domain itself or a
// single-label subdomain of one. Registered domains are read from a file
// (one domain per line) that `make <domain>.dnsdone` maintains.
package mapping

import (
	"bufio"
	"errors"
	"net"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

var labelRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`)

// ContainerName maps a hostname to a Podman container name and returns the
// registered domain it belongs to.
//
//	"alice.example.com" → "alice.example.com-web", "example.com"
//	"example.com"       → "example.com-web",       "example.com"
//	anything else       → error
func ContainerName(host string, domains []string) (name, domain string, err error) {
	host = normalize(host)

	// Longest match wins, so both example.com and sub.example.com can be
	// registered as separate zones.
	for _, d := range domains {
		if (host == d || strings.HasSuffix(host, "."+d)) && len(d) > len(domain) {
			domain = d
		}
	}
	if domain == "" {
		return "", "", errors.New("host not in any registered domain")
	}
	if host != domain {
		sub := strings.TrimSuffix(host, "."+domain)
		if strings.Contains(sub, ".") {
			return "", "", errors.New("multi-level subdomain not allowed")
		}
		if !labelRe.MatchString(sub) {
			return "", "", errors.New("invalid subdomain label")
		}
	}
	return host + "-web", domain, nil
}

func normalize(host string) string {
	host = strings.ToLower(host)
	host = strings.TrimSuffix(host, ".")
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	return host
}

// DomainFile is a registered-domain list re-read from disk whenever it changes,
// so `make <domain>.dnsdone` takes effect without restarting the proxies.
type DomainFile struct {
	path string

	mu      sync.Mutex
	checked time.Time
	mtime   time.Time
	domains []string
}

// NewDomainFile returns a DomainFile reading path.
func NewDomainFile(path string) *DomainFile {
	return &DomainFile{path: path}
}

// Domains returns the current domain list. The file is stat'ed at most once
// per second; on a read error the last known list is kept.
func (f *DomainFile) Domains() []string {
	f.mu.Lock()
	defer f.mu.Unlock()

	now := time.Now()
	if now.Sub(f.checked) < time.Second {
		return f.domains
	}
	f.checked = now

	st, err := os.Stat(f.path)
	if err != nil || st.ModTime().Equal(f.mtime) {
		return f.domains
	}
	fh, err := os.Open(f.path)
	if err != nil {
		return f.domains
	}
	defer fh.Close()

	var ds []string
	sc := bufio.NewScanner(fh)
	for sc.Scan() {
		d := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(sc.Text()), "."))
		if d == "" || strings.HasPrefix(d, "#") {
			continue
		}
		ds = append(ds, d)
	}
	f.mtime = st.ModTime()
	f.domains = ds
	return ds
}
