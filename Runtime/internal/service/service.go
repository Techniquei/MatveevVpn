package service

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"sync"
	"time"

	"github.com/miekg/dns"
	"matveevvpn/runtime/internal/fakedns"
	"matveevvpn/runtime/internal/network"
	"matveevvpn/runtime/internal/policy"
)

const operationBudget = 15 * time.Second

// Offline is not a node failure. Recovery must not advance while the physical
// network cannot confirm connectivity.
var errOffline = errors.New("physical_network_offline")
var errNoNodes = errors.New("no_selected_node")
var errUnhealthy = errors.New("tunnel_unhealthy")

type RuntimeProcess interface {
	Call(context.Context, string, []byte, string) (WorkerReply, error)
	Done() <-chan struct{}
	Close() error
}
type Network interface {
	Discover(context.Context) (network.Physical, error)
	Apply(context.Context, network.Physical, string, []string) error
	Restore(context.Context) error
	Reclaim(context.Context) error
}
type Transport interface {
	Resolve(context.Context, *dns.Msg, fakedns.Action) (*dns.Msg, error)
	Bootstrap(context.Context, string) ([]string, error)
	Probe(context.Context, bool) error
	ProbeTCP(context.Context, string) error
	Close()
}
type Options struct {
	Directory      string
	Binary         string
	DNSAddress     string
	Network        Network
	Launch         func(string, string, string) (RuntimeProcess, error)
	Validate       func(context.Context, string, string, string, []byte) error
	Resolver       func(network.Physical) (Transport, error)
	Watch          func(context.Context) (<-chan struct{}, error)
	RulesFile      string
	HealthInterval time.Duration
	RetryInterval  time.Duration
	// AppInstalled reports whether the bundle that installed the service is
	// still present. Nil skips the check. Quitting the app is not removal.
	AppInstalled     func() bool
	AppCheckInterval time.Duration
	AppMissingGrace  time.Duration
}
type Status struct {
	AcceptedRevision uint64    `json:"acceptedRevision"`
	SnapshotID       string    `json:"snapshotID,omitempty"`
	DesiredOn        bool      `json:"desiredOn"`
	ActiveRevision   uint64    `json:"activeRevision,omitempty"`
	NodeID           string    `json:"nodeID,omitempty"`
	RuntimeState     string    `json:"runtimeState"`
	LastSuccess      time.Time `json:"lastSuccess,omitempty"`
	Error            string    `json:"error,omitempty"`
	Phase            string    `json:"phase,omitempty"`
	Diagnostics      []string  `json:"diagnostics,omitempty"`
}
type Service struct {
	mu            sync.Mutex
	runtimeMu     sync.Mutex
	options       Options
	store         *StateStore
	accepted      Accepted
	policy        *policy.Policy
	status        Status
	generation    uint64
	cancel        context.CancelFunc
	prepareCancel context.CancelFunc
	runtimeDone   chan struct{}
	pending       bool
	disabled      bool
	appMissing    bool
	closed        bool
	table         *fakedns.Store
	dnsHandler    *fakedns.Handler
	dnsServer     *fakedns.Server
	changed       chan struct{}
	switches      []time.Time
	ctx           context.Context
	shutdown      context.CancelFunc
	diagnostics   []string
}

func Open(options Options) (*Service, error) {
	store, a, p, err := OpenState(options.Directory)
	if err != nil {
		return nil, err
	}
	if options.Network == nil {
		return nil, errors.New("missing_network_boundary")
	}
	if options.Launch == nil {
		options.Launch = func(b, a, d string) (RuntimeProcess, error) { return LaunchWorker(b, a, d) }
	}
	if options.Validate == nil {
		options.Validate = ValidateWorker
	}
	if options.Resolver == nil {
		options.Resolver = func(p network.Physical) (Transport, error) { return NewResolver(p) }
	}
	if options.Watch == nil {
		options.Watch = network.Watch
	}
	if options.HealthInterval <= 0 {
		options.HealthInterval = 15 * time.Second
	}
	if options.RetryInterval <= 0 {
		options.RetryInterval = 30 * time.Second
	}
	if options.DNSAddress == "" {
		options.DNSAddress = "127.0.0.1:53"
	}
	for _, name := range []string{"assets", "run"} {
		if privateDirectory(filepath.Join(options.Directory, name)) != nil {
			return nil, ErrPersistence
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &Service{options: options, store: store, accepted: a, policy: p, status: Status{RuntimeState: "off"}, changed: make(chan struct{}, 1), ctx: ctx, shutdown: cancel}
	// Reconcile orphan processes and the emergency network journal before serving
	// requests or restoring a persisted desired-on configuration.
	if err = ReapWorker(filepath.Join(options.Directory, "run"), options.Binary); err != nil {
		cancel()
		return nil, err
	}
	cleanup, c := context.WithTimeout(ctx, operationBudget)
	err = options.Network.Restore(cleanup)
	c()
	if err != nil {
		cancel()
		return nil, err
	}
	s.table, err = fakedns.Open(filepath.Join(options.Directory, "dns"))
	if err != nil {
		cancel()
		return nil, err
	}
	s.dnsHandler = &fakedns.Handler{Store: s.table}
	s.dnsServer, err = fakedns.StartServer(options.DNSAddress, s.dnsHandler)
	if err != nil {
		s.table.Close()
		cancel()
		return nil, err
	}
	go s.watchRoutes()
	// A bundle that is already gone must not bring the tunnel up, including
	// after reboot. Grace applies only to a bundle that disappears later.
	if options.AppInstalled != nil && !options.AppInstalled() {
		s.appMissing = true
	}
	go s.watchAppBundle()
	s.mu.Lock()
	if a.DesiredOn && !s.appMissing {
		s.reconcileLocked()
	}
	s.mu.Unlock()
	return s, nil
}
func (s *Service) DNSAddress() string { return s.dnsServer.Address() }

// Route notifications only wake the current reconcile. A privileged AF_ROUTE
// socket may be unavailable; health checks still re-read the physical route.
func (s *Service) watchRoutes() {
	events, err := s.options.Watch(s.ctx)
	if err != nil || events == nil {
		return
	}
	for {
		select {
		case <-s.ctx.Done():
			return
		case _, ok := <-events:
			if !ok {
				return
			}
			s.NetworkChanged()
		}
	}
}
func (s *Service) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	status := s.status
	status.Diagnostics = append([]string(nil), s.diagnostics...)
	status.AcceptedRevision = s.accepted.Revision
	status.SnapshotID = s.accepted.SnapshotID
	status.DesiredOn = s.accepted.DesiredOn && !s.disabled
	if status.RuntimeState == "connected" && time.Since(status.LastSuccess) > 30*time.Second {
		status.RuntimeState = "recovering"
	}
	return status
}

func (s *Service) Apply(ctx context.Context, id string, expected uint64, snapshot policy.Snapshot) (Status, error) {
	encoded, _ := json.Marshal(snapshot)
	payload := hash(encoded)
	s.mu.Lock()
	if err := s.admitLocked(id, expected, payload); err != nil {
		s.mu.Unlock()
		return s.Status(), err
	}
	if s.accepted.LastRequestID == id {
		s.mu.Unlock()
		return s.Status(), nil
	}
	if s.pending {
		s.mu.Unlock()
		return s.Status(), errors.New("operation_busy")
	}
	s.pending = true
	generation := s.generation
	prep, cancel := context.WithTimeout(ctx, operationBudget)
	s.prepareCancel = cancel
	s.mu.Unlock()
	defer func() { cancel(); s.mu.Lock(); s.pending = false; s.prepareCancel = nil; s.mu.Unlock() }()
	p, err := policy.Compile(snapshot)
	if err != nil {
		return s.Status(), err
	}
	if len(snapshot.Nodes) > 0 {
		stage, err := os.MkdirTemp(filepath.Join(s.options.Directory, "assets"), "validate-")
		if err != nil {
			return s.Status(), ErrPersistence
		}
		defer os.RemoveAll(stage)
		assets, config, err := s.prepare(p, p.SelectedNode().ID, "lo0", "utun999", "127.0.0.1", nil, stage)
		if err != nil {
			return s.Status(), err
		}
		if err = s.options.Validate(prep, s.options.Binary, assets, s.table.Directory(), config); err != nil {
			if s.superseded(generation, expected, ctx) {
				return s.Status(), errors.New("operation_cancelled")
			}
			return s.Status(), errors.New("configuration_rejected")
		}
	}
	s.mu.Lock()
	if s.closed || s.disabled || generation != s.generation || expected != s.accepted.Revision || ctx.Err() != nil {
		s.mu.Unlock()
		return s.Status(), errors.New("operation_cancelled")
	}
	snapshotID, err := s.store.SaveSnapshot(snapshot)
	if err == nil {
		next := s.accepted
		next.Revision++
		next.SnapshotID = snapshotID
		next.PreviousSnapshotID = s.accepted.SnapshotID
		next.LastRequestID = id
		next.LastRequestPayloadHash = payload
		err = s.store.Commit(next)
		if err == nil {
			s.accepted = next
			s.policy = p
			s.reconcileLocked()
			_ = s.store.Prune(next)
		}
	}
	s.mu.Unlock()
	if err != nil {
		return s.Status(), ErrPersistence
	}
	return s.Status(), nil
}

func (s *Service) superseded(generation, expected uint64, ctx context.Context) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed || s.disabled || generation != s.generation || expected != s.accepted.Revision || ctx.Err() != nil
}

func (s *Service) SetDesiredOn(ctx context.Context, id string, expected uint64, on bool) (Status, error) {
	payload := hash([]byte("desiredOn=" + map[bool]string{false: "false", true: "true"}[on]))
	s.mu.Lock()
	if err := s.admitLocked(id, expected, payload); err != nil {
		s.mu.Unlock()
		return s.Status(), err
	}
	if s.accepted.LastRequestID == id {
		s.mu.Unlock()
		return s.Status(), nil
	}
	if on && (s.policy == nil || s.policy.SelectedNode().ID == "") {
		s.mu.Unlock()
		return s.Status(), errors.New("no_selected_node")
	}
	next := s.accepted
	next.Revision++
	next.DesiredOn = on
	next.LastRequestID = id
	next.LastRequestPayloadHash = payload
	err := s.store.Commit(next)
	if err == nil {
		s.accepted = next
	} else if !on {
		s.disabled = true
	}
	if err == nil || !on {
		s.reconcileLocked()
	}
	done := s.runtimeDone
	s.mu.Unlock()
	if !on && done != nil {
		select {
		case <-done:
		case <-ctx.Done():
			return s.Status(), errors.New("cleanup_timeout")
		}
	}
	if err != nil {
		return s.Status(), ErrPersistence
	}
	return s.Status(), nil
}
func (s *Service) admitLocked(id string, expected uint64, payload string) error {
	if s.closed {
		return errors.New("service_closed")
	}
	if s.disabled {
		return ErrPersistence
	}
	if len(id) == 0 || len(id) > 64 {
		return errors.New("invalid_request")
	}
	if s.accepted.LastRequestID == id {
		if payload != s.accepted.LastRequestPayloadHash {
			return errors.New("request_id_conflict")
		}
		return nil
	}
	if expected != s.accepted.Revision {
		return errors.New("revision_conflict")
	}
	return nil
}

func (s *Service) reconcileLocked() {
	s.generation++
	generation := s.generation
	if s.cancel != nil {
		s.cancel()
	}
	if s.prepareCancel != nil {
		s.prepareCancel()
	}
	// Suspend before returning accepted state: no fresh DNS answer may use a
	// policy that differs from the current worker's revision.
	s.dnsHandler.Suspend()
	ctx, cancel := context.WithCancel(s.ctx)
	s.cancel = cancel
	done := make(chan struct{})
	s.runtimeDone = done
	a, p := s.accepted, s.policy
	missing := s.appMissing
	if !a.DesiredOn || s.disabled || missing {
		s.status = Status{RuntimeState: "stopping"}
	} else {
		s.status = Status{RuntimeState: "starting"}
	}
	go func() {
		defer close(done)
		s.runtimeMu.Lock()
		defer s.runtimeMu.Unlock()
		if ctx.Err() != nil {
			return
		}
		if !a.DesiredOn || s.disabled || missing {
			err := s.cleanup()
			status := Status{RuntimeState: "off"}
			// Desired-off already reports its own result. A missing app must
			// retry restoration until the network journal is clear.
			if missing && err != nil {
				status = Status{RuntimeState: "error", Error: "network_cleanup_failed"}
			}
			s.publish(generation, status)
			return
		}
		s.run(ctx, generation, a, p)
	}()
}
func (s *Service) publish(generation uint64, status Status) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if generation == s.generation && !s.closed {
		if status.RuntimeState != s.status.RuntimeState || status.Phase != s.status.Phase || status.Error != s.status.Error {
			entry := time.Now().UTC().Format(time.RFC3339) + " state=" + status.RuntimeState
			if status.Phase != "" {
				entry += " phase=" + status.Phase
			}
			if status.Error != "" {
				entry += " error=" + status.Error
			}
			s.diagnostics = append(s.diagnostics, entry)
			if len(s.diagnostics) > 24 {
				s.diagnostics = s.diagnostics[len(s.diagnostics)-24:]
			}
		}
		s.status = status
	}
}
func (s *Service) cleanup() error {
	s.dnsHandler.Suspend()
	ctx, cancel := context.WithTimeout(context.Background(), operationBudget)
	defer cancel()
	return s.options.Network.Restore(ctx)
}

func (s *Service) prepare(p *policy.Policy, nodeID, iface, tun, server string, lan []string, directory string) (string, []byte, error) {
	snapshot := p.Snapshot
	snapshot.SelectedNodeID = nodeID
	active, err := policy.Compile(snapshot)
	if err != nil {
		return "", nil, err
	}
	dnsAddress := s.options.DNSAddress
	if s.dnsServer != nil && s.dnsServer.Address() != "" {
		dnsAddress = s.dnsServer.Address()
	}
	artifacts, err := active.Build(policy.ConfigOptions{Interface: iface, TUN: tun, ServerIP: server, LAN: lan, DNSAddress: dnsAddress})
	if err != nil {
		return "", nil, err
	}
	if err = privateDirectory(directory); err != nil {
		return "", nil, ErrPersistence
	}
	for name, data := range map[string][]byte{"policy-domains.dat": artifacts.Domains, "policy-ips.dat": artifacts.IPs} {
		if err = atomicPrivateWrite(filepath.Join(directory, name), data); err != nil {
			return "", nil, ErrPersistence
		}
	}
	return directory, artifacts.Config, nil
}

func (s *Service) run(ctx context.Context, generation uint64, a Accepted, p *policy.Policy) {
	defer s.cleanup()
	if p == nil {
		s.publish(generation, Status{RuntimeState: "error", Error: "no_selected_node"})
		return
	}
	order := []policy.Node{p.SelectedNode(), p.SelectedNode()}
	for _, n := range p.Snapshot.Nodes {
		if n.ID != p.SelectedNode().ID && len(order) < 4 {
			order = append(order, n)
		}
	}
	position := 0
	for ctx.Err() == nil {
		s.publish(generation, Status{RuntimeState: "starting", Phase: "network-discovery"})
		op, cancel := context.WithTimeout(ctx, operationBudget)
		physical, err := s.options.Network.Discover(op)
		if err != nil {
			cancel()
			s.publish(generation, Status{RuntimeState: "waiting-network", Phase: "network-discovery/" + network.DiscoveryStep(err), Error: "physical_network_unavailable"})
			if !s.wait(ctx) {
				return
			}
			continue
		}
		resolver, err := s.options.Resolver(physical)
		if err != nil {
			cancel()
			s.publish(generation, Status{RuntimeState: "error", Error: "resolver_unavailable"})
			return
		}
		// Selective mode would otherwise let a real-IP health check leave through
		// the direct outbound. The probe must dial the name's tunnel address.
		if dial, ok := resolver.(interface {
			SetTunnelAddress(func(string) (netip.Addr, error))
		}); ok && s.table != nil {
			dial.SetTunnelAddress(s.table.Allocate)
		}
		s.publish(generation, Status{RuntimeState: "starting", Phase: "physical-dns-probe"})
		directAvailable := resolver.Probe(op, true) == nil
		if !directAvailable {
			s.publish(generation, Status{RuntimeState: "starting", Phase: "physical-dns-probe", Error: "physical_dns_probe_failed"})
		}
		if position >= len(order) {
			position = 0
			if directAvailable {
				s.publish(generation, Status{RuntimeState: "error", Error: "recovery_exhausted"})
			} else {
				s.publish(generation, Status{RuntimeState: "waiting-network", Phase: "physical-dns-probe", Error: "physical_and_server_unreachable"})
			}
			resolver.Close()
			cancel()
			if !s.wait(ctx) {
				return
			}
			continue
		}
		node := order[position]
		if position >= 2 && directAvailable && !s.allowSwitch() {
			resolver.Close()
			cancel()
			s.publish(generation, Status{RuntimeState: "error", Error: "switch_limit"})
			if !s.wait(ctx) {
				return
			}
			continue
		}
		host, outbound, _ := policy.ParseNode(node)
		s.publish(generation, Status{RuntimeState: "starting", Phase: "server-resolution", NodeID: node.ID})
		addresses, err := resolver.Bootstrap(op, host)
		if err != nil || len(addresses) == 0 {
			resolver.Close()
			cancel()
			position++
			if !directAvailable && position < len(order) && order[position].ID == node.ID {
				position++
			}
			s.publish(generation, Status{RuntimeState: "starting", Phase: "server-resolution", Error: "bootstrap_failed", NodeID: node.ID})
			continue
		}
		// A blocked public DoH provider does not mean the VPN server is offline.
		// Confirm its physical path before making any TUN/DNS/route changes.
		settings := outbound["settings"].(map[string]any)
		port := strconv.Itoa(int(settings["port"].(float64)))
		physicalEndpoint := net.JoinHostPort(addresses[0], port)
		if !directAvailable {
			s.publish(generation, Status{RuntimeState: "starting", Phase: "server-connectivity", NodeID: node.ID})
			if resolver.ProbeTCP(op, physicalEndpoint) != nil {
				resolver.Close()
				cancel()
				position++
				if position < len(order) && order[position].ID == node.ID {
					position++
				}
				continue
			}
			if position >= 2 && !s.allowSwitch() {
				resolver.Close()
				cancel()
				s.publish(generation, Status{RuntimeState: "error", Error: "switch_limit"})
				return
			}
		}
		tun, err := freeTUN()
		if err != nil {
			resolver.Close()
			cancel()
			s.publish(generation, Status{RuntimeState: "error", Error: "tun_unavailable"})
			return
		}
		if !validServerIP(addresses[0]) {
			resolver.Close()
			cancel()
			s.publish(generation, Status{RuntimeState: "error", Error: "invalid_bootstrap"})
			return
		}
		if err = s.options.Network.Reclaim(op); err != nil {
			resolver.Close()
			cancel()
			s.publish(generation, Status{RuntimeState: "error", Error: "network_cleanup_failed"})
			return
		}
		assets, config, err := s.prepare(p, node.ID, physical.Interface, tun, addresses[0], physical.LANCIDRs, filepath.Join(s.options.Directory, "assets", "active"))
		if err != nil {
			resolver.Close()
			cancel()
			s.publish(generation, Status{RuntimeState: "error", Error: "configuration_rejected"})
			return
		}
		s.publish(generation, Status{RuntimeState: "starting", Phase: "worker-start", NodeID: node.ID})
		worker, err := s.options.Launch(s.options.Binary, assets, filepath.Join(s.options.Directory, "run"))
		failurePhase := "worker-start"
		if err == nil {
			failurePhase = "engine-start"
			s.publish(generation, Status{RuntimeState: "starting", Phase: failurePhase, NodeID: node.ID})
			_, err = worker.Call(op, "start", config, s.table.Directory())
		}
		if err == nil {
			failurePhase = "network-apply"
			s.publish(generation, Status{RuntimeState: "starting", Phase: failurePhase, NodeID: node.ID})
			err = s.options.Network.Apply(op, physical, tun, addresses)
		}
		if err == nil && ctx.Err() == nil {
			s.dnsHandler.Decision = func(name string) fakedns.Action {
				switch p.Decision(name) {
				case policy.Block:
					return fakedns.Block
				case policy.Local:
					return fakedns.Local
				case policy.VPN:
					return fakedns.VPN
				default:
					return fakedns.Direct
				}
			}
			s.dnsHandler.Resolve = resolver.Resolve
			err = s.dnsHandler.Activate(a.Revision)
		}
		cancel()
		if err == nil {
			failurePhase = "tunnel-health"
			s.publish(generation, Status{RuntimeState: "starting", Phase: failurePhase, NodeID: node.ID})
			err = s.monitor(ctx, generation, a.Revision, node.ID, physicalEndpoint, physical, worker, resolver)
		}
		if err != nil && ctx.Err() == nil {
			s.publish(generation, Status{RuntimeState: "starting", Phase: failurePhase, Error: "runtime_attempt_failed", NodeID: node.ID})
		}
		s.dnsHandler.Suspend()
		if worker != nil {
			if closeErr := worker.Close(); closeErr != nil && err == nil {
				err = closeErr
			}
		}
		_ = os.RemoveAll(filepath.Join(s.options.Directory, "assets", "active"))
		resolver.Close()
		if cleanupErr := s.cleanup(); cleanupErr != nil {
			s.publish(generation, Status{RuntimeState: "error", Error: "network_cleanup_failed"})
			return
		}
		if ctx.Err() != nil {
			return
		}
		if errors.Is(err, context.DeadlineExceeded) {
			s.publish(generation, Status{RuntimeState: "error", Error: "startup_timeout"})
			return
		}
		if errors.Is(err, network.ErrConflict) || errors.Is(err, fakedns.ErrTable) {
			s.publish(generation, Status{RuntimeState: "error", Error: "network_or_dns_conflict"})
			return
		}
		// Rebind the same node after a route change. Offline must not consume a switch.
		if errors.Is(err, network.ErrChanged) {
			continue
		}
		if errors.Is(err, errOffline) {
			if !s.wait(ctx) {
				return
			}
			continue
		}
		if errors.Is(err, errUnhealthy) {
			// The node has not passed traffic yet. Retrying it before the other
			// servers only repeats a dead connection.
			position++
			if position < len(order) && order[position].ID == node.ID {
				position++
			}
			continue
		}
		position++
	}
}
func (s *Service) monitor(ctx context.Context, generation, revision uint64, node, physicalEndpoint string, physical network.Physical, worker RuntimeProcess, resolver Transport) error {
	failures := 0
	healthy := false
	for ctx.Err() == nil {
		probe, cancel := context.WithTimeout(ctx, 6*time.Second)
		current, networkErr := s.options.Network.Discover(probe)
		if networkErr != nil {
			cancel()
			s.publish(generation, Status{ActiveRevision: revision, NodeID: node, RuntimeState: "waiting-network"})
			return errOffline
		}
		if !reflect.DeepEqual(current, physical) {
			cancel()
			return network.ErrChanged
		}
		err := resolver.Probe(probe, false)
		if s.table.Err() != nil {
			err = fakedns.ErrTable
		}
		if err != nil && !errors.Is(err, fakedns.ErrTable) && resolver.Probe(probe, true) != nil && resolver.ProbeTCP(probe, physicalEndpoint) != nil {
			cancel()
			s.publish(generation, Status{ActiveRevision: revision, NodeID: node, RuntimeState: "waiting-network"})
			return errOffline
		}
		status := Status{ActiveRevision: revision, NodeID: node, RuntimeState: "connected"}
		if err == nil {
			failures = 0
			healthy = true
			status.LastSuccess = time.Now()
		} else {
			failures++
			status.RuntimeState = "recovering"
			status.Error = "tunnel_health_failed"
		}
		cancel()
		s.publish(generation, status)
		if errors.Is(err, fakedns.ErrTable) {
			return err
		}
		if !healthy {
			return errUnhealthy
		}
		if failures >= 3 {
			return ErrWorker
		}
		timer := time.NewTimer(s.options.HealthInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-worker.Done():
			timer.Stop()
			return ErrWorker
		case <-s.changed:
			timer.Stop()
		case <-timer.C:
		}
	}
	return ctx.Err()
}
func (s *Service) wait(ctx context.Context) bool {
	timer := time.NewTimer(s.options.RetryInterval)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-s.changed:
		return true
	case <-timer.C:
		return true
	}
}
func (s *Service) NetworkChanged() {
	select {
	case s.changed <- struct{}{}:
	default:
	}
}
func (s *Service) allowSwitch() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	kept := s.switches[:0]
	for _, at := range s.switches {
		if now.Sub(at) < 10*time.Minute {
			kept = append(kept, at)
		}
	}
	s.switches = kept
	if len(kept) >= 3 {
		return false
	}
	s.switches = append(s.switches, now)
	return true
}
func freeTUN() (string, error) {
	for n := 900; n < 1000; n++ {
		name := "utun" + smallInt(n)
		if _, err := net.InterfaceByName(name); err != nil {
			return name, nil
		}
	}
	return "", ErrWorker
}
func smallInt(n int) string {
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte(n%10) + '0'
		n /= 10
	}
	return string(b[i:])
}

func (s *Service) Close() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	s.generation++
	if s.cancel != nil {
		s.cancel()
	}
	s.shutdown()
	done := s.runtimeDone
	s.mu.Unlock()
	if done != nil {
		select {
		case <-done:
		case <-time.After(20 * time.Second):
			return errors.New("shutdown_timeout")
		}
	}
	s.dnsHandler.Suspend()
	serverErr := s.dnsServer.Close()
	tableErr := s.table.Close()
	cleanupErr := s.cleanup()
	return errors.Join(serverErr, tableErr, cleanupErr)
}

// Avoid accidentally treating a synthetic address as a server bootstrap IP.
func validServerIP(value string) bool {
	addr, err := netip.ParseAddr(value)
	return err == nil && addr.Is4() && !fakedns.Pool.Contains(addr)
}
