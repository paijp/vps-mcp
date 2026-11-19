// https://github.com/paijp/vps-subdomain-mcp

// list-containers: queries the Podman REST API and prints each container's
// name, IP address, and state to stdout (tab-separated).
//
// In one-shot mode (default): prints once and exits.
// In loop mode (--loop N):    prints every N seconds, with a "---" separator
//
//	after each batch; runs until killed.
//
// Install to: /usr/local/sbin/list-containers  (root-owned, mode 0755)
// Run directly as root or via the pipe in vps-proxy*.service.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

const (
	podmanSock  = "/run/podman/podman.sock"
	maxResponse = 1 << 20 // 1 MiB cap on API response body
	timeout     = 5 * time.Second
)

type container struct {
	Id              string   `json:"Id"`
	Names           []string `json:"Names"`
	State           string   `json:"State"`
	NetworkSettings struct {
		Networks map[string]struct {
			IPAddress string `json:"IPAddress"`
		} `json:"Networks"`
	} `json:"NetworkSettings"`
}

var client = &http.Client{
	Timeout: timeout,
	Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{Timeout: timeout}).DialContext(ctx, "unix", podmanSock)
		},
	},
}

// emit writes the current container list to out.  In loop mode the caller
// appends the "---" separator and flushes.
func emit(out *bufio.Writer) error {
	resp, err := client.Get("http://d/containers/json")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	var containers []container
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxResponse)).Decode(&containers); err != nil {
		return fmt.Errorf("parse: %v", err)
	}

	for _, c := range containers {
		name := ""
		if len(c.Names) > 0 {
			name = c.Names[0]
			if len(name) > 0 && name[0] == '/' {
				name = name[1:]
			}
		}
		ip := ""
		for _, n := range c.NetworkSettings.Networks {
			if n.IPAddress != "" {
				ip = n.IPAddress
				break
			}
		}
		if ip == "" && c.State == "running" && c.Id != "" {
			// Podman 6 leaves IPAddress empty in the list endpoint for
			// containers it created (older ones still report it), so ask
			// the per-container inspect endpoint, which always has it.
			ip = inspectIP(c.Id)
		}
		fmt.Fprintf(out, "%s\t%s\t%s\n", name, ip, c.State)
	}
	return nil
}

// inspectIP returns the container's first non-empty network IP from
// /containers/{id}/json, or "" on any error.
func inspectIP(id string) string {
	resp, err := client.Get("http://d/containers/" + id + "/json")
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	var c container
	if json.NewDecoder(io.LimitReader(resp.Body, maxResponse)).Decode(&c) != nil {
		return ""
	}
	for _, n := range c.NetworkSettings.Networks {
		if n.IPAddress != "" {
			return n.IPAddress
		}
	}
	return ""
}

func main() {
	loop := flag.Int("loop", 0, "seconds between updates (0=one-shot)")
	flag.Parse()

	out := bufio.NewWriter(os.Stdout)

	if *loop == 0 {
		if err := emit(out); err != nil {
			fmt.Fprintf(os.Stderr, "list-containers: %v\n", err)
			os.Exit(1)
		}
		out.Flush()
		return
	}

	// Loop mode: emit entries then "---" separator on each tick.
	tick := func() {
		if err := emit(out); err != nil {
			fmt.Fprintf(os.Stderr, "list-containers: %v\n", err)
			return
		}
		fmt.Fprintln(out, "---")
		out.Flush()
	}

	tick() // first run immediately
	ticker := time.NewTicker(time.Duration(*loop) * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		tick()
	}
}
