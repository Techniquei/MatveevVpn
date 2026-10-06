package network

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type fakeNetwork struct {
	t          *testing.T
	directory  string
	dns        []string
	routes     []route
	writes     []string
	legacyTun  string
	listeners  string
	failPrefix string
	failed     bool
	service    string
	gateway    string
}

func fakeFor(t *testing.T) *fakeNetwork {
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	return &fakeNetwork{t: t, directory: directory, service: "Wi-Fi", routes: []route{
		{Prefix: "0.0.0.0/0", Gateway: "192.168.50.1", Interface: "en0"},
		{Prefix: "192.168.50.0/24", Gateway: "link#6", Interface: "en0", ViaLink: true},
		{Prefix: "169.254.0.0/16", Gateway: "link#6", Interface: "en0", ViaLink: true},
		{Prefix: "127.0.0.0/8", Gateway: "127.0.0.1", Interface: "lo0"},
		{Prefix: "::/0", Gateway: "fe80::1%en0", Interface: "en0"},
		{Prefix: "::1/128", Gateway: "::1", Interface: "lo0"},
		{Prefix: "fe80::/64", Gateway: "link#6", Interface: "en0", ViaLink: true},
		{Prefix: "fd7a:115c:a1e0::/48", Gateway: "link#12", Interface: "utun3", ViaLink: true},
	}}
}

func (f *fakeNetwork) Run(ctx context.Context, executable string, args ...string) ([]byte, error) {
	f.t.Helper()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	key := executable + " " + strings.Join(args, " ")
	switch {
	case executable == scutil && reflect.DeepEqual(args, []string{"--nwi"}):
		return []byte("Network information\n  en0 : flags : 0x7 (IPv4,IPv6,DNS)\n"), nil
	case executable == scutil && reflect.DeepEqual(args, []string{"--dns"}):
		return []byte("resolver #1\n  nameserver[0] : 192.168.50.1\n  if_index : 6 (en0)\n"), nil
	case executable == networksetup && reflect.DeepEqual(args, []string{"-listnetworkserviceorder"}):
		return []byte(fmt.Sprintf("An asterisk (*) denotes a disabled network service.\n(1) %s\n(Hardware Port: Wi-Fi, Device: en0)\n", f.service)), nil
	case executable == networksetup && len(args) == 2 && args[0] == "-getdnsservers":
		if args[1] != f.service {
			return nil, errors.New("service missing")
		}
		if len(f.dns) == 0 {
			return []byte("There aren't any DNS Servers set on " + args[1] + ".\n"), nil
		}
		return []byte(strings.Join(f.dns, "\n") + "\n"), nil
	case executable == routeTool && len(args) >= 3 && args[1] == "get":
		if strings.Contains(key, "-inet6") {
			return []byte("gateway: fe80::1%en0\ninterface: en0\n"), nil
		}
		gateway := f.gateway
		if gateway == "" {
			gateway = "192.168.50.1"
		}
		return []byte("gateway: " + gateway + "\ninterface: en0\n"), nil
	case executable == netstat && reflect.DeepEqual(args, []string{"-an", "-f", "inet", "-p", "tcp"}):
		return []byte(f.listeners), nil
	case executable == netstat && len(args) == 3 && args[0] == "-rn":
		var output strings.Builder
		output.WriteString("Routing tables\nDestination Gateway Flags Netif Expire\n")
		for _, r := range f.routes {
			prefix := netip.MustParsePrefix(r.Prefix)
			if prefix.Addr().Is6() != (args[2] == "inet6") {
				continue
			}
			gateway, flags := r.Gateway, "UGSc"
			if gateway == "" {
				gateway = "link#20"
			}
			if r.Scoped {
				flags += "I"
			}
			fmt.Fprintf(&output, "%s %s %s %s\n", r.Prefix, gateway, flags, r.Interface)
		}
		return []byte(output.String()), nil
	case executable == ifconfigTool && len(args) == 1:
		if args[0] == f.legacyTun {
			return []byte("utun: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST>\n\tinet 172.19.0.1 --> 172.19.0.1 netmask 0xfffffffc\n"), nil
		}
		return []byte("utun: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST>\n\tinet 10.7.0.2 --> 10.7.0.2 netmask 0xffffffff\n"), nil
	case executable == ifconfigTool && len(args) == 2 && args[1] == "destroy":
		kept := f.routes[:0]
		for _, r := range f.routes {
			if r.Interface != args[0] {
				kept = append(kept, r)
			}
		}
		f.routes = kept
		f.legacyTun = ""
		return nil, nil
	}
	routeAdd := executable == routeTool && len(args) > 1 && args[1] == "add"
	if routeAdd || executable == networksetup && len(args) >= 1 && args[0] == "-setdnsservers" {
		// Every actual mutation, including recovery, must have durable intent.
		encoded, err := os.ReadFile(filepath.Join(f.directory, "network-journal.json"))
		if err != nil {
			f.t.Fatal("mutation before durable recovery journal", key, err)
		}
		var saved journal
		if json.Unmarshal(encoded, &saved) != nil || len(saved.Changes) == 0 {
			f.t.Fatal("mutation without recorded recovery entry", key)
		}
		if routeAdd {
			if len(args) < 5 {
				f.t.Fatal("route add has no prefix", key)
			}
			scoped := false
			for _, arg := range args {
				if arg == "-ifscope" {
					scoped = true
				}
			}
			recorded := false
			for _, change := range saved.Changes {
				if change.Kind == "route" && change.Route.Prefix == args[4] && change.Route.Scoped == scoped {
					recorded = true
					break
				}
			}
			if !recorded {
				f.t.Fatal("route add missing from recovery journal", args[4], scoped)
			}
		}
	}
	f.writes = append(f.writes, key)
	if f.failPrefix != "" && strings.HasPrefix(key, f.failPrefix) && !f.failed {
		f.failed = true
		return nil, errors.New("fake failure contains private diagnostic value")
	}
	switch {
	case executable == networksetup && len(args) >= 3 && args[0] == "-setdnsservers":
		if args[1] != f.service {
			return nil, errors.New("service missing")
		}
		f.dns = append([]string(nil), args[2:]...)
		if len(f.dns) == 1 && f.dns[0] == "Empty" {
			f.dns = nil
		}
	case executable == routeTool && len(args) >= 6 && (args[1] == "add" || args[1] == "delete"):
		r := route{Prefix: args[4], Interface: "en0"}
		if args[5] == "-interface" {
			r.ViaLink, r.Interface = true, args[6]
		} else {
			r.Gateway = args[5]
		}
		for i := 6; i+1 < len(args); i++ {
			if args[i] == "-ifscope" {
				r.Scoped = true
				r.Interface = args[i+1]
			}
		}
		if args[1] == "add" {
			f.routes = append(f.routes, r)
		} else {
			for i, existing := range f.routes {
				if matches(existing, r) {
					f.routes = append(f.routes[:i], f.routes[i+1:]...)
					break
				}
			}
		}
	case executable == "/usr/bin/dscacheutil" && reflect.DeepEqual(args, []string{"-flushcache"}):
	case executable == "/usr/bin/killall" && reflect.DeepEqual(args, []string{"-HUP", "mDNSResponder"}):
	default:
		f.t.Fatalf("unexpected executable or argument structure: %s", key)
	}
	return nil, nil
}

func openFake(t *testing.T, f *fakeNetwork) *Adapter {
	t.Helper()
	a, err := Open(f.directory, f)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func TestDiscoverPhysicalDuringTunnelUsesSavedResolverAndScopedRoute(t *testing.T) {
	f := fakeFor(t)
	a := openFake(t, f)
	p, err := a.Discover(context.Background())
	if err != nil || p.Interface != "en0" || p.Service != "Wi-Fi" || p.GatewayIPv4 != "192.168.50.1" || !equalDNS(p.DNS, []string{"192.168.50.1"}) {
		t.Fatalf("physical discovery failed: %+v %v", p, err)
	}
	if err := a.Apply(context.Background(), p, "utun900", []string{"203.0.113.8"}); err != nil {
		t.Fatal(err)
	}
	p, err = a.Discover(context.Background())
	if err != nil || !equalDNS(p.DNS, []string{"192.168.50.1"}) {
		t.Fatalf("bootstrap resolver recursed into overridden DNS: %+v %v", p, err)
	}
}

func TestBypassRoutesDoNotChangePhysicalIdentity(t *testing.T) {
	f := fakeFor(t)
	a := openFake(t, f)
	before, err := a.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Apply(context.Background(), before, "utun900", []string{"203.0.113.8"}); err != nil {
		t.Fatal(err)
	}
	after, err := a.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("installed bypass routes looked like a network change\nbefore: %+v\nafter:  %+v", before, after)
	}
}

func TestLiveLegacyTunnelIsLeftForConflictCheck(t *testing.T) {
	f := fakeFor(t)
	f.legacyTun = "utun4"
	f.listeners = "tcp4 0 0 172.19.0.1.59695 *.* LISTEN\n"
	f.routes = append(f.routes, route{Prefix: "0.0.0.0/0", Gateway: "link#19", Interface: "utun4", ViaLink: true})
	a := openFake(t, f)
	p, err := a.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Apply(context.Background(), p, "utun900", []string{"203.0.113.8"}); !errors.Is(err, ErrConflict) {
		t.Fatal("live legacy tunnel was reclaimed or accepted", err)
	}
	if _, exists := exactRoute(f.routes, "0.0.0.0/0", false); !exists || f.legacyTun != "utun4" {
		t.Fatal("live tunnel was destroyed", f.legacyTun, f.routes)
	}
}

func TestApplyAndCrashRecoveryRestoreOnlyOwnedChanges(t *testing.T) {
	f := fakeFor(t)
	f.dns = []string{"9.9.9.9", "1.1.1.1"}
	a := openFake(t, f)
	initialRoutes := append([]route(nil), f.routes...)
	p, err := a.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Apply(context.Background(), p, "utun900", []string{"203.0.113.8"}); err != nil {
		t.Fatal(err)
	}
	if !equalDNS(f.dns, []string{resolver}) {
		t.Fatal("DNS override missing")
	}
	for _, prefix := range []string{fakePool, "0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"} {
		if current, ok := exactRoute(f.routes, prefix, false); !ok || current.Interface != "utun900" {
			t.Fatal("tunnel route missing", prefix)
		}
	}
	for _, prefix := range []string{"0.0.0.0/1", "128.0.0.0/1"} {
		current, ok := exactRoute(f.routes, prefix, true)
		if !ok || current.Interface != "en0" || current.Gateway != "192.168.50.1" {
			t.Fatal("physical ifscope route missing", prefix, current, ok)
		}
	}
	// Reopening simulates a service crash before any cleanup acknowledgement.
	a = openFake(t, f)
	if err := a.Restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(f.routes, initialRoutes) || !reflect.DeepEqual(f.dns, []string{"9.9.9.9", "1.1.1.1"}) {
		t.Fatalf("recovery changed non-owned network: %+v %+v", f.routes, f.dns)
	}
	if _, err := os.Stat(filepath.Join(f.directory, "network-journal.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("completed recovery retained journal", err)
	}
}

func TestPartialApplyFailureRestoresAllPreviousActions(t *testing.T) {
	for _, failing := range []string{routeTool + " -n add -inet -net 128.0.0.0/1", networksetup + " -setdnsservers Wi-Fi 127.0.0.1"} {
		t.Run(failing, func(t *testing.T) {
			f := fakeFor(t)
			a := openFake(t, f)
			before := append([]route(nil), f.routes...)
			p, err := a.Discover(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			f.failPrefix = failing
			err = a.Apply(context.Background(), p, "utun900", []string{"203.0.113.8"})
			if !errors.Is(err, ErrCommand) || strings.Contains(err.Error(), "private") {
				t.Fatal("apply did not reject safely", err)
			}
			if len(f.dns) != 0 || !reflect.DeepEqual(f.routes, before) {
				t.Fatal("partial apply did not restore previous network")
			}
		})
	}
}

func TestCleanupPreservesExternalDNSAndRouteChanges(t *testing.T) {
	f := fakeFor(t)
	a := openFake(t, f)
	p, _ := a.Discover(context.Background())
	if err := a.Apply(context.Background(), p, "utun900", []string{"203.0.113.8"}); err != nil {
		t.Fatal(err)
	}
	f.dns = []string{"8.8.4.4"}
	for i := range f.routes {
		if f.routes[i].Prefix == "0.0.0.0/1" {
			f.routes[i].Interface = "utun42"
		}
	}
	if err := a.Restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	current, exists := exactRoute(f.routes, "0.0.0.0/1", false)
	if !exists || current.Interface != "utun42" || !reflect.DeepEqual(f.dns, []string{"8.8.4.4"}) {
		t.Fatal("cleanup overwrote another owner's network state")
	}
}

func TestExistingPrivateMeshRoutesRemainAndApplyIsIdempotent(t *testing.T) {
	f := fakeFor(t)
	f.routes = append(f.routes, route{Prefix: "10.0.0.0/8", Interface: "utun3", ViaLink: true})
	a := openFake(t, f)
	p, _ := a.Discover(context.Background())
	if err := a.Apply(context.Background(), p, "utun900", []string{"203.0.113.8"}); err != nil {
		t.Fatal(err)
	}
	before := len(f.writes)
	if err := a.Apply(context.Background(), p, "utun900", []string{"203.0.113.8"}); err != nil || len(f.writes) != before {
		t.Fatal("reconcile repeated root changes", err)
	}
	if mesh, exists := exactRoute(f.routes, "10.0.0.0/8", false); !exists || mesh.Interface != "utun3" {
		t.Fatal("mesh route was replaced")
	}
}

func TestNeighbourCacheDoesNotChangePhysicalNetwork(t *testing.T) {
	f := fakeFor(t)
	a := openFake(t, f)
	before, err := a.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	// macOS adds/removes these ARP and IPv6 neighbour entries while traffic
	// flows. They are host cache entries, not a new LAN or gateway.
	f.routes = append(f.routes,
		route{Prefix: "192.168.50.8/32", Gateway: "aa:bb:cc:dd:ee:ff", Interface: "en0"},
		route{Prefix: "192.168.50.9/32", Gateway: "link#6", Interface: "en0", ViaLink: true},
		route{Prefix: "fe80::abcd/128", Gateway: "aa:bb:cc:dd:ee:ff", Interface: "en0"},
	)
	after, err := a.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("neighbour cache restarted the VPN: before=%+v after=%+v", before, after)
	}
}

func TestDiscoveryReportsSafeFailureStage(t *testing.T) {
	f := fakeFor(t)
	f.dns = []string{"private-invalid-value"}
	a := openFake(t, f)
	_, err := a.Discover(context.Background())
	if !errors.Is(err, ErrDiscover) || DiscoveryStep(err) != "configured-dns" || strings.Contains(err.Error(), "private-invalid-value") {
		t.Fatalf("discovery failure lost its stage or exposed tool input: %v %s", err, DiscoveryStep(err))
	}
}

func TestGatewayChangeReplacesOwnedIfscopeRoutes(t *testing.T) {
	f := fakeFor(t)
	a := openFake(t, f)
	p, err := a.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Apply(context.Background(), p, "utun900", []string{"203.0.113.8"}); err != nil {
		t.Fatal(err)
	}
	f.gateway = "192.168.50.2"
	moved, err := a.Discover(context.Background())
	if err != nil || moved.GatewayIPv4 != "192.168.50.2" {
		t.Fatal(moved, err)
	}
	if err := a.Apply(context.Background(), moved, "utun900", []string{"203.0.113.8"}); err != nil {
		t.Fatal(err)
	}
	for _, prefix := range []string{"0.0.0.0/1", "128.0.0.0/1"} {
		current, ok := exactRoute(f.routes, prefix, true)
		if !ok || current.Gateway != "192.168.50.2" || current.Interface != "en0" {
			t.Fatal("ifscope route was not moved with the gateway", prefix, current, ok)
		}
		tunnel, ok := exactRoute(f.routes, prefix, false)
		if !ok || tunnel.Interface != "utun900" {
			t.Fatal("tunnel route missing after gateway change", prefix)
		}
	}
}

func TestConflictsRejectBeforeNetworkChanges(t *testing.T) {
	for _, conflict := range []route{
		{Prefix: "198.18.0.0/24", Interface: "en0", ViaLink: true},
		{Prefix: "2001:db8::/64", Interface: "en0", Gateway: "fe80::abcd%en0"},
		{Prefix: "0.0.0.0/1", Interface: "utun42", ViaLink: true},
		{Prefix: "0.0.0.0/1", Interface: "en1", Gateway: "10.0.0.1", Scoped: true},
	} {
		t.Run(conflict.Prefix+" "+conflict.Interface, func(t *testing.T) {
			f := fakeFor(t)
			f.routes = append(f.routes, conflict)
			a := openFake(t, f)
			p, _ := a.Discover(context.Background())
			if err := a.Apply(context.Background(), p, "utun900", nil); !errors.Is(err, ErrConflict) || len(f.writes) != 0 {
				t.Fatal("conflict changed host state", err)
			}
		})
	}
}

func TestPreviousSingBoxTunnelIsRemovedBeforeStartup(t *testing.T) {
	f := fakeFor(t)
	f.legacyTun = "utun4"
	f.routes = append(f.routes,
		route{Prefix: "0.0.0.0/0", Gateway: "link#19", Interface: "utun4", ViaLink: true},
		route{Prefix: "198.18.0.2/32", Gateway: "link#19", Interface: "utun4", ViaLink: true},
	)
	a := openFake(t, f)
	p, err := a.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Apply(context.Background(), p, "utun900", []string{"203.0.113.8"}); err != nil {
		t.Fatal(err)
	}
	for _, r := range f.routes {
		if r.Interface == "utun4" {
			t.Fatal("previous tunnel route remained", r.Prefix)
		}
	}
	foreign := fakeFor(t)
	foreign.routes = append(foreign.routes, route{Prefix: "0.0.0.0/0", Gateway: "link#19", Interface: "utun4", ViaLink: true})
	other := openFake(t, foreign)
	physical, _ := other.Discover(context.Background())
	if err := other.Apply(context.Background(), physical, "utun900", []string{"203.0.113.8"}); !errors.Is(err, ErrConflict) {
		t.Fatal("foreign tunnel was accepted", err)
	}
}

func TestConnectedPublicIPv6IsActualLANButGatewayRouteOutsideLANConflicts(t *testing.T) {
	f := fakeFor(t)
	f.routes = append(f.routes, route{Prefix: "2001:db8:50::/64", Interface: "en0", ViaLink: true})
	a := openFake(t, f)
	p, err := a.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, prefix := range p.LANCIDRs {
		found = found || prefix == "2001:db8:50::/64"
	}
	if !found {
		t.Fatal("connected global IPv6 prefix missing from actual LAN")
	}
	if err := a.Apply(context.Background(), p, "utun900", nil); err != nil {
		t.Fatal("normal IPv6 LAN rejected", err)
	}
	f.routes = append(f.routes, route{Prefix: "2001:db8:99::/64", Interface: "en0", Gateway: "fe80::abcd%en0"})
	if err := a.Apply(context.Background(), p, "utun900", nil); !errors.Is(err, ErrConflict) {
		t.Fatal("new public route outside LAN bypassed IPv6 guard", err)
	}
}

func TestRestoreFindsRenamedServiceWithoutOverwritingExternalDNS(t *testing.T) {
	f := fakeFor(t)
	a := openFake(t, f)
	p, _ := a.Discover(context.Background())
	if err := a.Apply(context.Background(), p, "utun900", nil); err != nil {
		t.Fatal(err)
	}
	f.service = "Renamed Wi-Fi"
	if err := a.Restore(context.Background()); err != nil || len(f.dns) != 0 {
		t.Fatal("renaming left our DNS override installed", err)
	}
}

func TestRestoreFailureKeepsJournalForRetry(t *testing.T) {
	f := fakeFor(t)
	a := openFake(t, f)
	p, _ := a.Discover(context.Background())
	if err := a.Apply(context.Background(), p, "utun900", nil); err != nil {
		t.Fatal(err)
	}
	f.failPrefix = networksetup + " -setdnsservers Wi-Fi Empty"
	if err := a.Restore(context.Background()); !errors.Is(err, ErrCommand) {
		t.Fatal("restore failure was hidden", err)
	}
	a = openFake(t, f)
	if err := a.Restore(context.Background()); err != nil || len(f.dns) != 0 {
		t.Fatal("restore retry lost saved automatic DNS", err)
	}
}

func TestOpenIsPassiveAndRejectsUnsafeJournal(t *testing.T) {
	f := fakeFor(t)
	_ = openFake(t, f)
	if len(f.writes) != 0 {
		t.Fatal("opening adapter changed networking")
	}
	path := filepath.Join(f.directory, "network-journal.json")
	if err := os.Symlink("/etc/hosts", path); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(f.directory, f); !errors.Is(err, ErrJournal) {
		t.Fatal("journal followed symlink", err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`{"version":1,"unexpected":"private"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(f.directory, f); !errors.Is(err, ErrJournal) {
		t.Fatal("invalid journal was silently discarded", err)
	}
}

func TestCanceledApplyDoesNotMutateAndExecBoundaryRejectsShell(t *testing.T) {
	f := fakeFor(t)
	a := openFake(t, f)
	p, _ := a.Discover(context.Background())
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := a.Apply(ctx, p, "utun900", nil); err == nil || len(f.writes) != 0 {
		t.Fatal("cancelled operation mutated network", err)
	}
	if _, err := (ExecRunner{}).Run(context.Background(), "/bin/sh", "-c", "private-value"); !errors.Is(err, ErrCommand) || strings.Contains(err.Error(), "private-value") {
		t.Fatal("executor allowed arbitrary executable or echoed argv", err)
	}
}

func TestServerAlreadyOnLANKeepsItsConnectedRoute(t *testing.T) {
	f := fakeFor(t)
	a := openFake(t, f)
	p, _ := a.Discover(context.Background())
	if err := a.Apply(context.Background(), p, "utun900", []string{"192.168.50.8"}); err != nil {
		t.Fatal(err)
	}
	if _, exists := exactRoute(f.routes, "192.168.50.8/32", false); exists {
		t.Fatal("on-link VPN server was redirected through default gateway")
	}
	info, err := os.Stat(filepath.Join(f.directory, "network-journal.json"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("emergency journal is not private", err)
	}
}

func TestNetstatParserHandlesAbbreviatedAndScopedDarwinPrefixes(t *testing.T) {
	for _, fixture := range []struct{ source, family, want string }{
		{"192.168.50", "inet", "192.168.50.0/24"},
		{"127", "inet", "127.0.0.0/8"},
		{"10/8", "inet", "10.0.0.0/8"},
		{"fe80::%en0/64", "inet6", "fe80::/64"},
		{"fe80::1%en0", "inet6", "fe80::1/128"},
		{"default", "inet6", "::/0"},
	} {
		prefix, err := routePrefix(fixture.source, fixture.family)
		if err != nil || prefix.String() != fixture.want {
			t.Fatal(fixture.source, prefix, err)
		}
	}
	if _, err := parseRoutes("command unexpectedly empty", "inet"); err == nil {
		t.Fatal("invalid route table was interpreted as empty")
	}
}

func TestSteerProbeRouteIsTemporary(t *testing.T) {
	f := fakeFor(t)
	a := openFake(t, f)
	if _, err := a.Steer(context.Background(), "198.18.0.5"); !errors.Is(err, ErrInvalid) {
		t.Fatal("fakedns address accepted", err)
	}
	release, err := a.Steer(context.Background(), "203.0.113.9")
	if err != nil {
		t.Fatal(err)
	}
	release()
	if _, ok := exactRoute(f.routes, "203.0.113.9/32", false); ok {
		t.Fatal("steer without a tunnel installed a route")
	}
	initial := append([]route(nil), f.routes...)
	p, err := a.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Apply(context.Background(), p, "utun900", []string{"203.0.113.8"}); err != nil {
		t.Fatal(err)
	}
	before := len(f.routes)
	release, err = a.Steer(context.Background(), "10.9.9.9")
	if err != nil || len(f.routes) != before {
		t.Fatal("private address was given a public bypass", err)
	}
	release()
	release, err = a.Steer(context.Background(), "203.0.113.8")
	if err != nil {
		t.Fatal(err)
	}
	release()
	if current, ok := exactRoute(f.routes, "203.0.113.8/32", false); !ok || current.Gateway != "192.168.50.1" {
		t.Fatal("active server bypass was removed", f.routes)
	}
	release, err = a.Steer(context.Background(), "203.0.113.9")
	if err != nil {
		t.Fatal(err)
	}
	added, ok := exactRoute(f.routes, "203.0.113.9/32", false)
	if !ok || added.Gateway != "192.168.50.1" || added.Interface != "en0" {
		t.Fatal("probe bypass missing", f.routes)
	}
	encoded, err := os.ReadFile(filepath.Join(f.directory, "network-journal.json"))
	if err != nil || !strings.Contains(string(encoded), "203.0.113.9/32") {
		t.Fatal("probe bypass was not journaled", err)
	}
	release()
	release()
	if _, ok := exactRoute(f.routes, "203.0.113.9/32", false); ok {
		t.Fatal("probe bypass remained after release")
	}
	if _, ok := exactRoute(f.routes, "0.0.0.0/1", false); !ok {
		t.Fatal("tunnel route was removed with the probe")
	}
	encoded, err = os.ReadFile(filepath.Join(f.directory, "network-journal.json"))
	if err != nil || strings.Contains(string(encoded), "203.0.113.9/32") {
		t.Fatal("released probe route stayed in the journal", err)
	}
	if _, err := a.Steer(context.Background(), "203.0.113.9"); err != nil {
		t.Fatal(err)
	}
	a = openFake(t, f)
	if err := a.Restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(f.routes, initial) {
		t.Fatalf("crash recovery left probe or tunnel routes: %+v", f.routes)
	}
}
