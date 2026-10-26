// https://github.com/paijp/vps-subdomain-mcp

// vps-proxy-http: TCP passthrough proxy for port 80.
// Reads the first HTTP request bytes, extracts the Host header,
// and TCP-proxies the connection to the matching container without
// any header modification.  HTTPS redirect responsibility lies with
// the container's nginx.
// Must be run under vps-proxy80.socket (systemd socket activation).
package main

import (
	"bytes"
	"context"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"time"

	"github.com/paijp/vps-subdomain-mcp/proxy/internal/activation"
	"github.com/paijp/vps-subdomain-mcp/proxy/mapping"
	"github.com/paijp/vps-subdomain-mcp/proxy/routes"
)

func main() {
	domainsFile := flag.String("domains-file", "/etc/vps-mcp/domains", "registered domains, one per line")
	flag.Parse()
	domains := mapping.NewDomainFile(*domainsFile)

	table := routes.New(os.Stdin)
	go table.Run(context.Background())

	ls, err := activation.Listeners()
	if err != nil {
		log.Fatalf("activation: %v", err)
	}
	if len(ls) == 0 {
		log.Fatal("vps-proxy-http: no socket activation listener; run under vps-proxy80.socket")
	}
	ln := ls[0]
	log.Printf("vps-proxy-http: listening on %s (domains-file=%s)", ln.Addr(), *domainsFile)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go handle(conn, domains, table)
	}
}

func handle(conn net.Conn, domains *mapping.DomainFile, table *routes.Table) {
	defer conn.Close()

	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	buf := make([]byte, 8192)
	n, err := conn.Read(buf)
	conn.SetReadDeadline(time.Time{})
	if err != nil || n == 0 {
		return
	}
	data := buf[:n]

	// Extract the Host header value from the raw HTTP request.
	var host string
	for _, line := range bytes.Split(data, []byte("\r\n")) {
		lower := strings.ToLower(string(line))
		if strings.HasPrefix(lower, "host:") {
			host = strings.TrimSpace(string(line[5:]))
			break
		}
	}
	if host == "" {
		return
	}

	containerName, domain, err := mapping.ContainerName(host, domains.Domains())
	if err != nil {
		log.Printf("mapping %q: %v", host, err)
		return
	}

	// Unknown subdomains fall back to the domain's apex container.
	ip, ok := table.LookupIP(containerName)
	if !ok {
		ip, ok = table.LookupIP(domain + "-web")
	}
	if !ok {
		log.Printf("no route: %s (no container, no %s-web)", host, domain)
		return
	}

	backend, err := net.DialTimeout("tcp", net.JoinHostPort(ip, "80"), 10*time.Second)
	if err != nil {
		log.Printf("dial %s: %v", ip, err)
		return
	}
	defer backend.Close()

	// Replay the buffered bytes, then copy bidirectionally.
	if _, err := backend.Write(data); err != nil {
		return
	}

	go io.Copy(backend, conn) //nolint:errcheck
	io.Copy(conn, backend)    //nolint:errcheck
}
