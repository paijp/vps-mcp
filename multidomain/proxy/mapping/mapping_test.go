// https://github.com/paijp/vps-subdomain-mcp

package mapping_test

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/paijp/vps-subdomain-mcp/proxy/mapping"
)

var domains = []string{"example.com", "example.org", "example.net", "sub.example.net"}

func TestContainerName(t *testing.T) {
	cases := []struct {
		host       string
		want       string
		wantDomain string
		wantErr    bool
	}{
		{"alice.example.com", "alice.example.com-web", "example.com", false},
		{"example.com", "example.com-web", "example.com", false},
		{"test.example.org", "test.example.org-web", "example.org", false},
		{"example.org", "example.org-web", "example.org", false},
		// registered domain that is itself a subdomain
		{"sub.example.net", "sub.example.net-web", "sub.example.net", false},
		{"a.sub.example.net", "a.sub.example.net-web", "sub.example.net", false},
		// normalization
		{"Alice.Example.Com", "alice.example.com-web", "example.com", false},
		{"alice.example.com.", "alice.example.com-web", "example.com", false},
		{"alice.example.com:80", "alice.example.com-web", "example.com", false},
		// errors
		// deeper names go to the container of the label below the domain
		{"alice.bob.example.com", "bob.example.com-web", "example.com", false},
		{"x.y.alice.example.com", "alice.example.com-web", "example.com", false},
		{"http.iot0.sub.example.net", "iot0.sub.example.net-web", "sub.example.net", false},
		{"a_b.bob.example.com", "", "", true}, // invalid label in a deeper name
		{"other.domain.com", "", "", true},    // unregistered
		{"b.example.net", "b.example.net-web", "example.net", false},
		{"example.edu", "", "", true},        // unregistered
		{"alice_.example.com", "", "", true}, // invalid char
		{"-alice.example.com", "", "", true}, // leading hyphen
		{"alice-.example.com", "", "", true}, // trailing hyphen
		{"a.example.com", "a.example.com-web", "example.com", false},
	}

	for _, c := range cases {
		got, dom, err := mapping.ContainerName(c.host, domains)
		if c.wantErr {
			if err == nil {
				t.Errorf("ContainerName(%q) = %q, want error", c.host, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("ContainerName(%q) error: %v", c.host, err)
		} else if got != c.want || dom != c.wantDomain {
			t.Errorf("ContainerName(%q) = %q, %q; want %q, %q", c.host, got, dom, c.want, c.wantDomain)
		}
	}
}

func TestDomainFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "domains")
	if err := os.WriteFile(p, []byte("# comment\nExample.com.\n\nexample.org\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := mapping.NewDomainFile(p).Domains()
	want := []string{"example.com", "example.org"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Domains() = %v, want %v", got, want)
	}

	if got := mapping.NewDomainFile(filepath.Join(t.TempDir(), "missing")).Domains(); len(got) != 0 {
		t.Errorf("missing file: Domains() = %v, want empty", got)
	}
}
