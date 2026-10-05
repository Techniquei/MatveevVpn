package lists

import (
	"strings"

	"matveevvpn/runtime/internal/policy"
)

// Intent is the typed user request. List expansion stays in this package.
type Intent struct {
	Nodes          []policy.Node `json:"nodes"`
	SelectedNodeID string        `json:"selectedNodeID"`
	SubscriptionURL string       `json:"subscriptionURL,omitempty"`
	Mode           string        `json:"mode"`
	Presets        []string      `json:"presets,omitempty"`
	UserDomains    []string      `json:"userDomains,omitempty"`
	BlockDomains   []string      `json:"blockDomains,omitempty"`
	AdBlocking     bool          `json:"adBlocking,omitempty"`
}

// Compile expands presets and user domains into one admitted snapshot.
func Compile(intent Intent) (*policy.Policy, error) {
	snapshot := policy.Snapshot{
		Nodes:           append([]policy.Node(nil), intent.Nodes...),
		SelectedNodeID:  intent.SelectedNodeID,
		SubscriptionURL: intent.SubscriptionURL,
		Mode:            intent.Mode,
		BlockDomains:    append([]string(nil), intent.BlockDomains...),
	}
	seen := map[string]bool{}
	for _, name := range intent.Presets {
		if seen[name] {
			return nil, ErrRejected
		}
		seen[name] = true
		domains, ips, err := Preset(name, policy.VPN)
		if err != nil {
			return nil, err
		}
		snapshot.Domains = append(snapshot.Domains, domains...)
		snapshot.IPs = append(snapshot.IPs, ips...)
	}
	for _, domain := range intent.UserDomains {
		domain = strings.TrimPrefix(strings.ToLower(strings.TrimSpace(domain)), "*.")
		snapshot.Domains = append(snapshot.Domains, policy.DomainRule{Kind: "suffix", Value: domain, Route: policy.VPN})
	}
	return policy.Compile(snapshot)
}
