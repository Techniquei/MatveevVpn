// Package policy owns admission and the shared DNS/traffic routing decision.
package policy

import (
	"encoding/json"
	"errors"
	"net/netip"
	"net/url"
	"regexp"
	"strings"
)

const MaxSnapshotBytes = 32 << 20

var ErrInvalid = errors.New("invalid_snapshot")

type Route string

const (
	Direct Route = "direct"
	VPN    Route = "vpn"
	Block  Route = "block"
	Local  Route = "local"
)

type Node struct {
	ID  string `json:"id"`
	URI string `json:"uri"`
}
type DomainRule struct {
	Kind  string `json:"kind"`
	Value string `json:"value"`
	Route Route  `json:"route"`
}
type IPRule struct {
	Prefix string `json:"prefix"`
	Route  Route  `json:"route"`
}

// Lists are already normalized by the source importer. No runtime JSON or paths
// cross this boundary; unsupported source operators must be rejected there.
type Snapshot struct {
	Nodes           []Node       `json:"nodes"`
	SelectedNodeID  string       `json:"selectedNodeID"`
	SubscriptionURL string       `json:"subscriptionURL,omitempty"`
	Mode            string       `json:"mode"`
	Domains         []DomainRule `json:"domains,omitempty"`
	IPs             []IPRule     `json:"ips,omitempty"`
	BlockDomains    []string     `json:"blockDomains,omitempty"`
	RulesVersion    string       `json:"rulesVersion,omitempty"`
}

type matchRule struct {
	DomainRule
	expression *regexp.Regexp
}
type Policy struct {
	Snapshot Snapshot
	rules    []matchRule
	blocked  map[string]bool
}

var labels = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)
var InterfaceName = regexp.MustCompile(`^[a-z][a-z0-9]{0,15}$`)

func Domain(value string) bool {
	if len(value) == 0 || len(value) > 253 || value != strings.ToLower(value) {
		return false
	}
	for _, label := range strings.Split(value, ".") {
		if !labels.MatchString(label) {
			return false
		}
	}
	return true
}

func Compile(s Snapshot) (*Policy, error) {
	encoded, err := json.Marshal(s)
	if err != nil || len(encoded) > MaxSnapshotBytes || len(s.Nodes) > 512 || len(s.Domains) > 200000 || len(s.BlockDomains) > 200000 || len(s.IPs) > 50000 || len(s.RulesVersion) > 128 {
		return nil, ErrInvalid
	}
	// The admitted policy is immutable even when an in-process caller reuses its
	// draft slices after Apply. JSON is already the canonical external boundary.
	if json.Unmarshal(encoded, &s) != nil {
		return nil, ErrInvalid
	}
	if s.Mode != "all" && s.Mode != "selective" {
		return nil, ErrInvalid
	}
	if s.SubscriptionURL != "" {
		u, e := url.Parse(s.SubscriptionURL)
		if e != nil || u.Scheme != "https" || u.Host == "" || len(s.SubscriptionURL) > 8192 {
			return nil, ErrInvalid
		}
	}
	ids := map[string]bool{}
	selected := s.SelectedNodeID == "" && len(s.Nodes) == 0
	for _, n := range s.Nodes {
		if len(n.ID) == 0 || len(n.ID) > 64 || ids[n.ID] {
			return nil, ErrInvalid
		}
		ids[n.ID] = true
		if _, _, err := ParseNode(n); err != nil {
			return nil, err
		}
		if n.ID == s.SelectedNodeID {
			selected = true
		}
	}
	if !selected {
		return nil, ErrInvalid
	}
	p := &Policy{Snapshot: s, blocked: map[string]bool{}}
	for _, d := range s.BlockDomains {
		if !Domain(d) || !strings.Contains(d, ".") {
			return nil, ErrInvalid
		}
		p.blocked[d] = true
	}
	for _, r := range s.Domains {
		if r.Route != VPN && r.Route != Direct && r.Route != Block {
			return nil, ErrInvalid
		}
		m := matchRule{DomainRule: r}
		switch r.Kind {
		case "exact", "suffix":
			if !Domain(r.Value) {
				return nil, ErrInvalid
			}
		case "keyword":
			if len(r.Value) == 0 || len(r.Value) > 253 || strings.ContainsAny(r.Value, "\x00\r\n") {
				return nil, ErrInvalid
			}
		case "regex":
			if len(r.Value) == 0 || len(r.Value) > 2048 {
				return nil, ErrInvalid
			}
			m.expression, err = regexp.Compile(r.Value)
			if err != nil {
				return nil, ErrInvalid
			}
		default:
			return nil, ErrInvalid
		}
		p.rules = append(p.rules, m)
	}
	for _, r := range s.IPs {
		if r.Route != VPN && r.Route != Direct && r.Route != Block {
			return nil, ErrInvalid
		}
		prefix, e := netip.ParsePrefix(r.Prefix)
		if e != nil || prefix != prefix.Masked() {
			return nil, ErrInvalid
		}
	}
	return p, nil
}

func (p *Policy) SelectedNode() Node {
	for _, n := range p.Snapshot.Nodes {
		if n.ID == p.Snapshot.SelectedNodeID {
			return n
		}
	}
	return Node{}
}

func (p *Policy) Decision(name string) Route {
	name = strings.TrimSuffix(strings.ToLower(name), ".")
	if !strings.Contains(name, ".") || name == "local" || strings.HasSuffix(name, ".local") || strings.HasSuffix(name, ".in-addr.arpa") || strings.HasSuffix(name, ".ip6.arpa") {
		return Local
	}
	// Service probes use the tunnel even in selective mode and cannot be blocked
	// by an external ad list. These are fixed service destinations, not user rules.
	if name == "api4.ipify.org" || name == "www.cloudflare.com" {
		return VPN
	}
	for suffix := name; ; {
		if p.blocked[suffix] {
			return Block
		}
		i := strings.IndexByte(suffix, '.')
		if i < 0 {
			break
		}
		suffix = suffix[i+1:]
	}
	for _, r := range p.rules {
		if r.Route == Block && r.matches(name) {
			return Block
		}
	}
	for _, r := range p.rules {
		if r.Route != Block && r.matches(name) {
			return r.Route
		}
	}
	if p.Snapshot.Mode == "all" {
		return VPN
	}
	return Direct
}
func (r matchRule) matches(name string) bool {
	switch r.Kind {
	case "exact":
		return name == r.Value
	case "suffix":
		return name == r.Value || strings.HasSuffix(name, "."+r.Value)
	case "keyword":
		return strings.Contains(name, r.Value)
	case "regex":
		return r.expression.MatchString(name)
	}
	return false
}
