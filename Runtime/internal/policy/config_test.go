package policy

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	corelog "github.com/xtls/xray-core/common/log"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/features/routing"
	routingSession "github.com/xtls/xray-core/features/routing/session"
	_ "github.com/xtls/xray-core/main/distro/all"
)

func testOptions() ConfigOptions {
	return ConfigOptions{Interface: "en0", TUN: "utun900", ServerIP: "203.0.113.10", LAN: []string{"100.64.0.0/10"}}
}

func TestLargeAdListUsesCompactPrivateAssets(t *testing.T) {
	s := testSnapshot()
	for i := 0; i < 70000; i++ {
		s.BlockDomains = append(s.BlockDomains, fmt.Sprintf("ad%d.ads.test", i))
	}
	p, err := Compile(s)
	if err != nil {
		t.Fatal(err)
	}
	a, err := p.Build(testOptions())
	if err != nil {
		t.Fatal(err)
	}
	if len(a.Config) > 1<<20 || len(a.Domains) <= 1<<20 {
		t.Fatalf("large list was not externalized: config=%d domains=%d", len(a.Config), len(a.Domains))
	}
	if bytes.Contains(a.Config, []byte("ad69999.ads.test")) || !bytes.Contains(a.Config, []byte("ext:policy-domains.dat:")) {
		t.Fatal("ad list expanded into bounded worker input")
	}
}

func TestGeneratedConfigSelectsModeWithoutTerminalCatchAll(t *testing.T) {
	for _, mode := range []string{"all", "selective"} {
		s := testSnapshot()
		s.Mode = mode
		p, err := Compile(s)
		if err != nil {
			t.Fatal(err)
		}
		a, err := p.Build(testOptions())
		if err != nil {
			t.Fatal(err)
		}
		var config map[string]any
		if json.Unmarshal(a.Config, &config) != nil {
			t.Fatal("invalid config")
		}
		first := config["outbounds"].([]any)[0].(map[string]any)["tag"]
		want := "direct"
		if mode == "all" {
			want = "vpn"
		}
		if first != want {
			t.Fatalf("mode=%s default=%s", mode, first)
		}
		for _, raw := range config["routing"].(map[string]any)["rules"].([]any) {
			rule := raw.(map[string]any)
			if _, ok := rule["network"]; ok && len(rule) == 3 {
				t.Fatal("catchall prevents real-IP pass for unresolved domain")
			}
		}
		if config["routing"].(map[string]any)["domainStrategy"] != "IPIfNonMatch" {
			t.Fatal("real IP presets disabled")
		}
		inbound := config["inbounds"].([]any)[0].(map[string]any)
		for _, key := range []string{"autoSystemRoutingTable", "autoSystemDnsToGateway", "autoOutboundsInterface"} {
			if _, ok := inbound["settings"].(map[string]any)[key]; ok {
				t.Fatalf("core controls service networking via %s", key)
			}
		}
		if _, ok := config["fakeDns"]; ok {
			t.Fatal("second FakeDNS allocator")
		}
	}
}

func TestGeodataConstructsAndMatchesInIsolatedProcess(t *testing.T) {
	if os.Getenv("MATVEEV_POLICY_CORE_HELPER") == "1" {
		constructAndMatchCore(t)
		return
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(executable, "-test.run=^TestGeodataConstructsAndMatchesInIsolatedProcess$")
	command.Env = append(os.Environ(), "MATVEEV_POLICY_CORE_HELPER=1")
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("isolated constructor/matcher failed: %v\n%s", err, output.Bytes())
		}
	case <-time.After(10 * time.Second):
		_ = command.Process.Kill()
		<-done
		t.Fatal("isolated core construction exceeded deadline")
	}
}

type discardLogs struct{}

func (discardLogs) Handle(corelog.Message) {}

func constructAndMatchCore(t *testing.T) {
	s := testSnapshot()
	s.Domains = []DomainRule{{Kind: "exact", Value: "ads.test", Route: Direct}, {Kind: "exact", Value: "exact.test", Route: VPN}, {Kind: "suffix", Value: "suffix.test", Route: VPN}, {Kind: "keyword", Value: "media", Route: VPN}, {Kind: "regex", Value: `^rx[0-9]+\.test$`, Route: VPN}, {Kind: "exact", Value: "blocked.test", Route: Direct}, {Kind: "exact", Value: "blocked.test", Route: Block}}
	s.BlockDomains = []string{"ads.test"}
	s.IPs = []IPRule{{Prefix: "192.0.2.0/24", Route: VPN}}
	p, err := Compile(s)
	if err != nil {
		t.Fatal(err)
	}
	a, err := p.Build(testOptions())
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	for name, data := range map[string][]byte{"policy-domains.dat": a.Domains, "policy-ips.dat": a.IPs} {
		if os.WriteFile(filepath.Join(directory, name), data, 0600) != nil {
			t.Fatal("asset publication failed")
		}
	}
	t.Setenv("XRAY_LOCATION_ASSET", directory)
	corelog.RegisterHandler(discardLogs{})
	cfg, err := core.LoadConfig("json", bytes.NewReader(a.Config))
	if err != nil {
		t.Fatal(err)
	}
	instance, err := core.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer instance.Close()
	// Never Start: this exercise cannot create a host TUN or change networking.
	manager := instance.GetFeature(outbound.ManagerType()).(outbound.Manager)
	if manager.GetDefaultHandler().Tag() != "direct" {
		t.Fatal("selective core default differs from DNS policy")
	}
	router := instance.GetFeature(routing.RouterType()).(routing.Router)
	for _, fixture := range []struct {
		name string
		want Route
	}{{"exact.test", VPN}, {"sub.suffix.test", VPN}, {"suffix.test", VPN}, {"cdn.media.test", VPN}, {"rx12.test", VPN}, {"ads.test", Block}, {"sub.ads.test", Block}, {"blocked.test", Block}, {"192.0.2.22", VPN}, {"198.18.0.1", Block}, {"10.1.2.3", Direct}, {"100.64.0.3", Direct}, {"2001:db8::1", Block}, {"api4.ipify.org", VPN}} {
		ctx := &routingSession.Context{Outbound: &session.Outbound{Target: xnet.TCPDestination(xnet.ParseAddress(fixture.name), 443)}}
		route, err := router.PickRoute(ctx)
		if err != nil || route.GetOutboundTag() != string(fixture.want) {
			t.Fatalf("core %s decision differs: %v %v", fixture.name, route, err)
		}
	}
	for _, link := range []string{
		"vmess://11111111-1111-1111-1111-111111111111@vmess.example:443?encryption=auto",
		"trojan://secret@trojan.example:443?sni=trojan.example",
		"ss://YWVzLTEyOC1nY206cGFzc3dvcmQ@ss.example:8388",
		"hysteria2://auth@hy2.example:443?sni=hy2.example",
	} {
		snapshot := testSnapshot()
		snapshot.Nodes[0].URI = link
		compiled, err := Compile(snapshot)
		if err != nil {
			t.Fatalf("%s: %v", link, err)
		}
		built, err := compiled.Build(testOptions())
		if err != nil {
			t.Fatalf("%s: %v", link, err)
		}
		loaded, err := core.LoadConfig("json", bytes.NewReader(built.Config))
		if err != nil {
			t.Fatalf("%s: %v", link, err)
		}
		next, err := core.New(loaded)
		if err != nil {
			t.Fatalf("%s: %v", link, err)
		}
		next.Close()
	}
}

func TestDNSEndpointStaysOnTheServiceLoopback(t *testing.T) {
	p, err := Compile(testSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	options := testOptions()
	options.DNSAddress = "127.0.0.1:5353"
	artifacts, err := p.Build(options)
	if err != nil || !bytes.Contains(artifacts.Config, []byte(`"port":5353`)) {
		t.Fatalf("service DNS port was not preserved: %v", err)
	}
	options.DNSAddress = "8.8.8.8:53"
	if _, err = p.Build(options); !errors.Is(err, ErrInvalid) {
		t.Fatalf("public DNS endpoint was accepted: %v", err)
	}
}
