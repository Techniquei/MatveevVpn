package service

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/miekg/dns"
	"matveevvpn/runtime/internal/fakedns"
	"matveevvpn/runtime/internal/network"
	"matveevvpn/runtime/internal/policy"
)

const (
	nodeAURI = "vless://11111111-1111-1111-1111-111111111111@server.test:443?encryption=none"
	nodeBURI = "vless://22222222-2222-2222-2222-222222222222@other.test:443?encryption=none"
)

func serviceSnapshot() policy.Snapshot {
	return policy.Snapshot{
		Mode:           "selective",
		Nodes:          []policy.Node{{ID: "node-a", URI: nodeAURI}, {ID: "node-b", URI: nodeBURI}},
		SelectedNodeID: "node-a",
		BlockDomains:   []string{"ads.example"},
		Domains:        []policy.DomainRule{{Kind: "exact", Value: "vpn.example", Route: policy.VPN}},
	}
}

type harness struct {
	dir           string
	service       *Service
	mu            sync.Mutex
	configs       [][]byte
	launches      int
	discovers     int
	order         []string
	ifaces        []string
	ifaceIndex    int
	directErr     error
	tcpProbe      func(context.Context, string) error
	tunnelErr     error
	holdTunnel    chan struct{}
	health        time.Duration
	retry         time.Duration
	events        chan struct{}
	validateErr   error
	blockValidate <-chan struct{}
	validateReady chan struct{}
	appInstalled  func() bool
	appGrace      time.Duration
	appInterval   time.Duration
}

func newHarness(t *testing.T, tweak func(*harness)) *harness {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	h := &harness{dir: dir, ifaces: []string{"en0"}, health: time.Hour, retry: time.Hour}
	if tweak != nil {
		tweak(h)
	}
	events := h.events
	svc, err := Open(Options{
		Directory:        h.dir,
		DNSAddress:       "127.0.0.1:0",
		Network:          h,
		Launch:           h.launch,
		Validate:         h.validate,
		Resolver:         func(network.Physical) (Transport, error) { return h, nil },
		HealthInterval:   h.health,
		RetryInterval:    h.retry,
		AppInstalled:     h.appInstalled,
		AppCheckInterval: h.appInterval,
		AppMissingGrace:  h.appGrace,
		Watch: func(context.Context) (<-chan struct{}, error) {
			if events == nil {
				return make(chan struct{}), nil
			}
			return events, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	h.service = svc
	t.Cleanup(func() { _ = h.service.Close() })
	return h
}

func (h *harness) Discover(context.Context) (network.Physical, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.discovers++
	name := h.ifaces[min(h.ifaceIndex, len(h.ifaces)-1)]
	h.ifaceIndex++
	h.order = append(h.order, "discover:"+name)
	return network.Physical{Interface: name, GatewayIPv4: "192.0.2.1", Service: "Wi-Fi", DNS: []string{"192.0.2.53"}}, nil
}

func (h *harness) Apply(context.Context, network.Physical, string, []string) error { return nil }

func (h *harness) Reclaim(context.Context) error { return nil }

func (h *harness) Restore(context.Context) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.order = append(h.order, "restore")
	return nil
}

func (h *harness) Resolve(_ context.Context, query *dns.Msg, _ fakedns.Action) (*dns.Msg, error) {
	answer := new(dns.Msg)
	answer.SetReply(query)
	answer.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: query.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60}, A: net.IPv4(10, 1, 2, 3)}}
	return answer, nil
}

func (h *harness) Bootstrap(_ context.Context, host string) ([]string, error) {
	switch host {
	case "server.test":
		return []string{"203.0.113.10"}, nil
	case "other.test":
		return []string{"203.0.113.20"}, nil
	default:
		return nil, ErrResolver
	}
}

func (h *harness) Probe(ctx context.Context, direct bool) error {
	h.mu.Lock()
	if direct {
		err := h.directErr
		h.mu.Unlock()
		return err
	}
	err := h.tunnelErr
	hold := h.holdTunnel
	h.order = append(h.order, "tunnel-probe")
	h.mu.Unlock()
	if hold != nil {
		select {
		case <-hold:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return err
}

func (h *harness) Close() {}

func (h *harness) ProbeTCP(ctx context.Context, address string) error {
	if h.tcpProbe != nil {
		return h.tcpProbe(ctx, address)
	}
	dialer := &net.Dialer{Timeout: time.Second}
	conn, err := dialer.DialContext(ctx, "tcp4", address)
	if err != nil {
		return err
	}
	return conn.Close()
}

func (h *harness) launch(string, string, string) (RuntimeProcess, error) {
	h.mu.Lock()
	h.launches++
	h.order = append(h.order, "launch")
	h.mu.Unlock()
	return &fakeWorker{owner: h, done: make(chan struct{})}, nil
}

func (h *harness) validate(ctx context.Context, _, _, _ string, _ []byte) error {
	if h.validateReady != nil {
		select {
		case <-h.validateReady:
		default:
			close(h.validateReady)
		}
	}
	if h.blockValidate != nil {
		select {
		case <-h.blockValidate:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return h.validateErr
}

func (h *harness) copiedConfigs() [][]byte {
	h.mu.Lock()
	defer h.mu.Unlock()
	copied := make([][]byte, len(h.configs))
	for i, config := range h.configs {
		copied[i] = append([]byte(nil), config...)
	}
	return copied
}

func (h *harness) counts() (launches, discovers int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.launches, h.discovers
}

func (h *harness) copiedOrder() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.order...)
}

type fakeWorker struct {
	owner *harness
	done  chan struct{}
	once  sync.Once
}

func (w *fakeWorker) Call(_ context.Context, _ string, config []byte, _ string) (WorkerReply, error) {
	w.owner.mu.Lock()
	w.owner.configs = append(w.owner.configs, append([]byte(nil), config...))
	w.owner.mu.Unlock()
	return WorkerReply{Version: 1, ID: "worker", Success: true, Running: true, Core: "test"}, nil
}

func (w *fakeWorker) Done() <-chan struct{} { return w.done }

func (w *fakeWorker) Close() error {
	w.once.Do(func() { close(w.done) })
	return nil
}

func waitStatus(t *testing.T, svc *Service, match func(Status) bool) Status {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var last Status
	for time.Now().Before(deadline) {
		last = svc.Status()
		if match(last) {
			return last
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("status %+v", last)
	return last
}

func waitConfigs(t *testing.T, h *harness, count int) [][]byte {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		configs := h.copiedConfigs()
		if len(configs) >= count {
			return configs
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("worker configs = %d, want at least %d", len(h.copiedConfigs()), count)
	return nil
}

func dnsPort(t *testing.T, config []byte) int {
	t.Helper()
	var parsed map[string]any
	if json.Unmarshal(config, &parsed) != nil {
		t.Fatal("worker config is not JSON")
	}
	for _, raw := range parsed["outbounds"].([]any) {
		outbound := raw.(map[string]any)
		if outbound["tag"] == "dns" {
			return int(outbound["settings"].(map[string]any)["port"].(float64))
		}
	}
	t.Fatal("dns outbound missing")
	return 0
}

func pollDNS(t *testing.T, address, name string, want int) *dns.Msg {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	var last *dns.Msg
	var err error
	for time.Now().Before(deadline) {
		query := new(dns.Msg)
		query.SetQuestion(dns.Fqdn(name), dns.TypeA)
		last, _, err = (&dns.Client{Net: "udp", Timeout: 300 * time.Millisecond}).Exchange(query, address)
		if err == nil && last.Rcode == want {
			return last
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("dns %s: %v rcode %v", name, err, last)
	return nil
}

func TestApplyRejectsBeforeCommit(t *testing.T) {
	h := newHarness(t, func(h *harness) { h.validateErr = errors.New("rejected") })
	status, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot())
	if err == nil || err.Error() != "configuration_rejected" || strings.Contains(err.Error(), "secret-token") {
		t.Fatalf("validation error escaped: %v", err)
	}
	launches, _ := h.counts()
	if status.AcceptedRevision != 0 || launches != 0 {
		t.Fatalf("rejected apply changed state: %+v launches %d", status, h.launches)
	}
	entries, err := os.ReadDir(filepath.Join(h.dir, "snapshots"))
	if err != nil || len(entries) != 0 {
		t.Fatalf("snapshot was committed before validation: %v %d", err, len(entries))
	}
}

func TestApplyRequestIdentityAndRevision(t *testing.T) {
	h := newHarness(t, nil)
	ctx := context.Background()
	first, err := h.service.Apply(ctx, "apply-1", 0, serviceSnapshot())
	if err != nil || first.AcceptedRevision != 1 {
		t.Fatalf("first apply: %+v %v", first, err)
	}
	repeat, err := h.service.Apply(ctx, "apply-1", 0, serviceSnapshot())
	if err != nil || repeat.AcceptedRevision != 1 {
		t.Fatalf("duplicate request reapplied: %+v %v", repeat, err)
	}
	changed := serviceSnapshot()
	changed.RulesVersion = "other-payload"
	if _, err = h.service.Apply(ctx, "apply-1", 1, changed); err == nil || err.Error() != "request_id_conflict" {
		t.Fatalf("payload conflict: %v", err)
	}
	if _, err = h.service.Apply(ctx, "apply-2", 0, changed); err == nil || err.Error() != "revision_conflict" {
		t.Fatalf("stale revision: %v", err)
	}
	second, err := h.service.Apply(ctx, "apply-2", 1, changed)
	if err != nil || second.AcceptedRevision != 2 || second.SnapshotID == first.SnapshotID {
		t.Fatalf("second apply: %+v %v", second, err)
	}
	info, err := os.Lstat(filepath.Join(h.dir, "accepted.json"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("accepted record permissions: %v %v", info, err)
	}
}

func TestApplyIsBusyWhileValidationIsOutstanding(t *testing.T) {
	release := make(chan struct{})
	h := newHarness(t, func(h *harness) {
		h.blockValidate = release
		h.validateReady = make(chan struct{})
	})
	done := make(chan error, 1)
	go func() {
		_, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot())
		done <- err
	}()
	select {
	case <-h.validateReady:
	case <-time.After(2 * time.Second):
		t.Fatal("validation did not start")
	}
	if _, err := h.service.Apply(context.Background(), "apply-2", 0, serviceSnapshot()); err == nil || err.Error() != "operation_busy" {
		t.Fatalf("overlapping apply: %v", err)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestOffDuringValidationDoesNotCommit(t *testing.T) {
	h := newHarness(t, func(h *harness) { h.validateReady = make(chan struct{}); h.blockValidate = make(chan struct{}) })
	applyDone := make(chan error, 1)
	go func() {
		_, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot())
		applyDone <- err
	}()
	select {
	case <-h.validateReady:
	case <-time.After(2 * time.Second):
		t.Fatal("validation did not start")
	}
	status, err := h.service.SetDesiredOn(context.Background(), "off-1", 0, false)
	if err != nil || status.DesiredOn || status.AcceptedRevision != 1 {
		t.Fatalf("off during validation: %+v %v", status, err)
	}
	if err = <-applyDone; err == nil || err.Error() != "operation_cancelled" {
		t.Fatalf("cancelled apply: %v", err)
	}
	entries, _ := os.ReadDir(filepath.Join(h.dir, "snapshots"))
	launches, _ := h.counts()
	if len(entries) != 0 || launches != 0 {
		t.Fatalf("cancelled apply left a snapshot or worker: %d launches %d", len(entries), h.launches)
	}
}

func TestFailedOffStopsRuntimeWithoutDurableSuccess(t *testing.T) {
	h := newHarness(t, nil)
	if _, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.service.SetDesiredOn(context.Background(), "on-1", 1, true); err != nil {
		t.Fatal(err)
	}
	waitStatus(t, h.service, func(status Status) bool { return status.RuntimeState == "connected" })
	h.service.store.write = func(path string, data []byte) error {
		if strings.Contains(string(data), `"desiredOn":false`) {
			return errors.New("disk")
		}
		return atomicPrivateWrite(path, data)
	}
	status, err := h.service.SetDesiredOn(context.Background(), "off-1", 2, false)
	if !errors.Is(err, ErrPersistence) || status.DesiredOn || status.RuntimeState != "off" {
		t.Fatalf("failed off: %+v %v", status, err)
	}
	if _, err = h.service.Apply(context.Background(), "apply-2", status.AcceptedRevision, serviceSnapshot()); !errors.Is(err, ErrPersistence) {
		t.Fatalf("session recovered after persistence failure: %v", err)
	}
}

func TestReopenRestoresNetworkBeforeLaunch(t *testing.T) {
	h := newHarness(t, nil)
	if _, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.service.SetDesiredOn(context.Background(), "on-1", 1, true); err != nil {
		t.Fatal(err)
	}
	waitStatus(t, h.service, func(status Status) bool { return status.RuntimeState == "connected" })
	if err := h.service.Close(); err != nil {
		t.Fatal(err)
	}
	h.mu.Lock()
	h.order = nil
	h.mu.Unlock()
	reopened, err := Open(h.service.options)
	if err != nil {
		t.Fatal(err)
	}
	h.service = reopened
	waitStatus(t, reopened, func(status Status) bool { return status.RuntimeState == "connected" })
	order := h.copiedOrder()
	restoreAt, launchAt := -1, -1
	for i, event := range order {
		if event == "restore" && restoreAt < 0 {
			restoreAt = i
		}
		if event == "launch" && launchAt < 0 {
			launchAt = i
		}
	}
	if restoreAt < 0 || launchAt < restoreAt {
		t.Fatalf("reopen order %v", order)
	}
}

func TestOfflineDoesNotLaunchOrSwitch(t *testing.T) {
	h := newHarness(t, func(h *harness) {
		h.directErr = ErrHealth
		h.tcpProbe = func(context.Context, string) error { return ErrHealth }
		h.retry = 15 * time.Millisecond
	})
	if _, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.service.SetDesiredOn(context.Background(), "on-1", 1, true); err != nil {
		t.Fatal(err)
	}
	waitStatus(t, h.service, func(status Status) bool { return status.RuntimeState == "waiting-network" })
	time.Sleep(80 * time.Millisecond)
	launches, discovers := h.counts()
	if launches != 0 || discovers < 2 {
		t.Fatalf("offline consumed recovery: launches %d discovers %d", launches, discovers)
	}
	if _, err := h.service.SetDesiredOn(context.Background(), "off-1", 2, false); err != nil {
		t.Fatal(err)
	}
	waitStatus(t, h.service, func(status Status) bool { return status.RuntimeState == "off" })
	status := h.service.Status()
	if !strings.Contains(strings.Join(status.Diagnostics, "\n"), "phase=physical-dns-probe error=physical_dns_probe_failed") {
		t.Fatalf("disconnect erased startup failure: %+v", status)
	}
	if len(status.Diagnostics) > 24 {
		t.Fatal("unbounded diagnostic history")
	}
}

func TestBlockedPhysicalDoHCanConnectToReachableAlternative(t *testing.T) {
	h := newHarness(t, func(h *harness) {
		h.directErr = ErrHealth
		h.tcpProbe = func(_ context.Context, address string) error {
			if address == "203.0.113.20:443" {
				return nil
			}
			return ErrHealth
		}
	})
	if _, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.service.SetDesiredOn(context.Background(), "on-1", 1, true); err != nil {
		t.Fatal(err)
	}
	status := waitStatus(t, h.service, func(status Status) bool { return status.RuntimeState == "connected" })
	if status.NodeID != "node-b" {
		t.Fatalf("blocked DoH prevented failover: %+v", status)
	}
	if launches, _ := h.counts(); launches != 1 {
		t.Fatalf("unreachable server launched a worker: %d", launches)
	}
}

func TestTunnelFailuresSwitchWithinBudget(t *testing.T) {
	h := newHarness(t, func(h *harness) {
		h.tunnelErr = ErrHealth
		h.health = time.Millisecond
		h.retry = 5 * time.Millisecond
	})
	if _, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.service.SetDesiredOn(context.Background(), "on-1", 1, true); err != nil {
		t.Fatal(err)
	}
	waitStatus(t, h.service, func(status Status) bool { return status.Error == "switch_limit" })
	sawSelected, sawAlternate := false, false
	for _, config := range h.copiedConfigs() {
		sawSelected = sawSelected || bytesContains(config, "203.0.113.10")
		sawAlternate = sawAlternate || bytesContains(config, "203.0.113.20")
	}
	if !sawSelected || !sawAlternate {
		t.Fatal("recovery did not restart the selected node and then try an alternate")
	}
	stable, _ := h.counts()
	time.Sleep(40 * time.Millisecond)
	if launches, _ := h.counts(); launches != stable {
		t.Fatalf("switch limit did not hold: %d -> %d", stable, launches)
	}
}

func TestConnectedWaitsForTunnelProbe(t *testing.T) {
	hold := make(chan struct{})
	h := newHarness(t, func(h *harness) { h.holdTunnel = hold })
	if _, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.service.SetDesiredOn(context.Background(), "on-1", 1, true); err != nil {
		t.Fatal(err)
	}
	waitConfigs(t, h, 1)
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		h.mu.Lock()
		started := false
		for _, event := range h.order {
			started = started || event == "tunnel-probe"
		}
		h.mu.Unlock()
		if started {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if status := h.service.Status(); status.RuntimeState == "connected" {
		t.Fatalf("routes were reported connected before the tunnel probe: %+v", status)
	}
	close(hold)
	waitStatus(t, h.service, func(status Status) bool { return status.RuntimeState == "connected" })
}

func TestRouteChangesRebindTheSameNode(t *testing.T) {
	hold := make(chan struct{})
	h := newHarness(t, func(h *harness) {
		h.ifaces = []string{"en0", "en1", "en1", "en0", "en0"}
		h.holdTunnel = hold
	})
	if _, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.service.SetDesiredOn(context.Background(), "on-1", 1, true); err != nil {
		t.Fatal(err)
	}
	configs := waitConfigs(t, h, 3)
	for _, config := range configs {
		if bytesContains(config, "203.0.113.20") || !bytesContains(config, "203.0.113.10") {
			t.Fatal("route change advanced to another node")
		}
	}
}

func TestActiveDNSUsesListenerAndPrivateAssets(t *testing.T) {
	hold := make(chan struct{})
	h := newHarness(t, func(h *harness) { h.holdTunnel = hold })
	if _, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.service.SetDesiredOn(context.Background(), "on-1", 1, true); err != nil {
		t.Fatal(err)
	}
	configs := waitConfigs(t, h, 1)
	_, port, err := net.SplitHostPort(h.service.DNSAddress())
	if err != nil || dnsPort(t, configs[0]) != atoi(port) {
		t.Fatalf("worker DNS port %d listener %s", dnsPort(t, configs[0]), h.service.DNSAddress())
	}
	asset := filepath.Join(h.dir, "assets", "active", "policy-domains.dat")
	deadline := time.Now().Add(2 * time.Second)
	var info os.FileInfo
	for time.Now().Before(deadline) {
		info, err = os.Lstat(asset)
		if err == nil {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("asset permissions: %v %v", info, err)
	}
	directory, err := os.Lstat(filepath.Dir(asset))
	if err != nil || directory.Mode().Perm() != 0700 {
		t.Fatalf("asset directory permissions: %v %v", directory, err)
	}
	blocked := pollDNS(t, h.service.DNSAddress(), "ads.example", dns.RcodeNameError)
	if blocked.Rcode != dns.RcodeNameError {
		t.Fatalf("blocked domain rcode %d", blocked.Rcode)
	}
	answer := pollDNS(t, h.service.DNSAddress(), "vpn.example", dns.RcodeSuccess)
	record, ok := answer.Answer[0].(*dns.A)
	ip, parseOK := netip.AddrFromSlice(record.A)
	if !ok || !parseOK || !fakedns.Pool.Contains(ip.Unmap()) {
		t.Fatalf("vpn domain did not receive a pool address: %+v", answer)
	}
}

func TestStaleSuccessIsNotConnected(t *testing.T) {
	svc := &Service{accepted: Accepted{Revision: 4, DesiredOn: true, SnapshotID: "abc"}}
	svc.status = Status{RuntimeState: "connected", LastSuccess: time.Now().Add(-31 * time.Second), NodeID: "node-a"}
	if status := svc.Status(); status.RuntimeState != "recovering" || status.AcceptedRevision != 4 || !status.DesiredOn {
		t.Fatalf("stale success stayed connected: %+v", status)
	}
	svc.status.LastSuccess = time.Now()
	if svc.Status().RuntimeState != "connected" {
		t.Fatal("fresh success was downgraded")
	}
}

func TestTableErrorClearsConnectedAndKeepsSnapshot(t *testing.T) {
	hold := make(chan struct{})
	h := newHarness(t, func(h *harness) { h.holdTunnel = hold })
	applied, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if _, err = h.service.SetDesiredOn(context.Background(), "on-1", 1, true); err != nil {
		t.Fatal(err)
	}
	waitConfigs(t, h, 1)
	if err = h.service.table.Close(); err != nil {
		t.Fatal(err)
	}
	close(hold)
	status := waitStatus(t, h.service, func(status Status) bool { return status.Error == "network_or_dns_conflict" })
	if !status.DesiredOn || status.AcceptedRevision != applied.AcceptedRevision+1 || status.RuntimeState == "connected" {
		t.Fatalf("table error rolled back or stayed connected: %+v", status)
	}
	for _, config := range h.copiedConfigs() {
		if bytesContains(config, "203.0.113.20") {
			t.Fatal("table error switched nodes")
		}
	}
}

func TestRouteWatchWakesOfflineWait(t *testing.T) {
	events := make(chan struct{}, 1)
	h := newHarness(t, func(h *harness) {
		h.directErr = ErrHealth
		h.events = events
		h.retry = time.Hour
	})
	if _, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.service.SetDesiredOn(context.Background(), "on-1", 1, true); err != nil {
		t.Fatal(err)
	}
	waitStatus(t, h.service, func(status Status) bool { return status.RuntimeState == "waiting-network" })
	_, before := h.counts()
	events <- struct{}{}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if _, discovers := h.counts(); discovers > before {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("route notification left the offline wait on its hour timer")
}

func TestRejectedSnapshotDoesNotEchoSecrets(t *testing.T) {
	h := newHarness(t, nil)
	snapshot := serviceSnapshot()
	snapshot.SubscriptionURL = "http://secret-token.example/sub"
	_, err := h.service.Apply(context.Background(), "apply-1", 0, snapshot)
	if !errors.Is(err, policy.ErrInvalid) || strings.Contains(err.Error(), "secret-token") {
		t.Fatalf("unsafe admission error: %v", err)
	}
}

func TestAbsentAppBundleDoesNotStartOrKeepTheTunnel(t *testing.T) {
	var present atomic.Bool
	present.Store(true)
	h := newHarness(t, func(h *harness) {
		h.appInstalled = func() bool { return present.Load() }
		h.appGrace = 40 * time.Millisecond
		h.appInterval = 10 * time.Millisecond
	})
	if _, err := h.service.Apply(context.Background(), "apply-1", 0, serviceSnapshot()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.service.SetDesiredOn(context.Background(), "on-1", 1, true); err != nil {
		t.Fatal(err)
	}
	waitStatus(t, h.service, func(status Status) bool { return status.RuntimeState == "connected" })
	before, _ := h.counts()
	present.Store(false)
	stopped := waitStatus(t, h.service, func(status Status) bool { return status.RuntimeState == "off" })
	if !stopped.DesiredOn {
		t.Fatal("removing the app cleared the saved connection request")
	}
	time.Sleep(120 * time.Millisecond)
	if after, _ := h.counts(); after != before {
		t.Fatalf("tunnel restarted after the app disappeared: %d to %d", before, after)
	}

	if err := h.service.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(h.service.options)
	if err != nil {
		t.Fatal(err)
	}
	h.service = reopened
	time.Sleep(120 * time.Millisecond)
	quiet, _ := h.counts()
	if quiet != before || reopened.Status().RuntimeState != "off" {
		t.Fatalf("deleted app started a persisted tunnel: launches %d state %s", quiet, reopened.Status().RuntimeState)
	}
	status := reopened.Status()
	if _, err = reopened.SetDesiredOn(context.Background(), "on-2", status.AcceptedRevision, true); err != nil {
		t.Fatal(err)
	}
	time.Sleep(120 * time.Millisecond)
	if launches, _ := h.counts(); launches != quiet || reopened.Status().RuntimeState == "connected" {
		t.Fatalf("connect started the tunnel without the app: launches %d state %s", launches, reopened.Status().RuntimeState)
	}
	present.Store(true)
	waitStatus(t, reopened, func(status Status) bool { return status.RuntimeState == "connected" })
}

func bytesContains(data []byte, value string) bool { return strings.Contains(string(data), value) }

func atoi(value string) int {
	parsed := 0
	for _, c := range value {
		parsed = parsed*10 + int(c-'0')
	}
	return parsed
}
