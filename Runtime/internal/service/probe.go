package service

import (
	"context"
	"net"
	"net/url"
	"time"

	"matveevvpn/runtime/internal/policy"
)

type NodeProbe struct {
	ID                   string `json:"id"`
	Reachable            bool   `json:"reachable"`
	LatencyMilliseconds  int    `json:"latencyMilliseconds,omitempty"`
	Error                string `json:"error,omitempty"`
}

// routeSteer is implemented by the privileged network adapter. Tests that do
// not install tunnel routes omit it.
type routeSteer interface {
	Steer(context.Context, string) (func(), error)
}

type tunnelBootstrap interface {
	BootstrapThroughTunnel(context.Context, string) ([]string, error)
}

// ProbeNodes checks candidate servers through the physical network.
// It does not start, stop, or reconfigure the running worker.
func (s *Service) ProbeNodes(ctx context.Context, ids []string) ([]NodeProbe, error) {
	s.mu.Lock()
	current := s.policy
	s.mu.Unlock()
	if current == nil || len(current.Snapshot.Nodes) == 0 {
		return nil, errNoNodes
	}
	selected := map[string]bool{}
	if len(ids) == 0 {
		for _, node := range current.Snapshot.Nodes {
			selected[node.ID] = true
		}
	} else {
		for _, id := range ids {
			selected[id] = true
		}
	}
	op, cancel := context.WithTimeout(ctx, operationBudget)
	defer cancel()
	physical, err := s.options.Network.Discover(op)
	if err != nil {
		return nil, err
	}
	resolver, err := s.options.Resolver(physical)
	if err != nil {
		return nil, err
	}
	defer resolver.Close()
	var results []NodeProbe
	for _, node := range current.Snapshot.Nodes {
		if !selected[node.ID] {
			continue
		}
		results = append(results, s.probeOne(op, resolver, node))
	}
	if len(results) == 0 {
		return nil, errNoNodes
	}
	return results, nil
}

func (s *Service) probeOne(ctx context.Context, resolver Transport, node policy.Node) NodeProbe {
	result := NodeProbe{ID: node.ID}
	parsed, err := url.Parse(node.URI)
	if err != nil || parsed.Port() == "" {
		result.Error = "invalid_node"
		return result
	}
	host, _, err := policy.ParseNode(node)
	if err != nil {
		result.Error = "invalid_node"
		return result
	}
	addresses, err := resolver.Bootstrap(ctx, host)
	if err != nil || len(addresses) == 0 {
		if tunneled, ok := resolver.(tunnelBootstrap); ok {
			addresses, err = tunneled.BootstrapThroughTunnel(ctx, host)
		}
	}
	if err != nil || len(addresses) == 0 {
		result.Error = "bootstrap_failed"
		return result
	}
	if steer, ok := s.options.Network.(routeSteer); ok {
		release, steerErr := steer.Steer(ctx, addresses[0])
		if steerErr != nil {
			result.Error = "unreachable"
			return result
		}
		defer release()
	}
	started := time.Now()
	if err := resolver.ProbeTCP(ctx, net.JoinHostPort(addresses[0], parsed.Port())); err != nil {
		result.Error = "unreachable"
		return result
	}
	elapsed := int(time.Since(started) / time.Millisecond)
	if elapsed < 1 {
		elapsed = 1
	}
	result.Reachable = true
	result.LatencyMilliseconds = elapsed
	return result
}
