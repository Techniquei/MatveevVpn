package policy

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"strings"
	"testing"
)

const testNodeURI = "vless://11111111-1111-1111-1111-111111111111@server.test:443?encryption=none"

func testSnapshot() Snapshot {
	return Snapshot{Mode: "selective", Nodes: []Node{{ID: "node-1", URI: testNodeURI}}, SelectedNodeID: "node-1"}
}

func TestSharedDomainDecisionPreservesMatchingAndPriority(t *testing.T) {
	snapshot := testSnapshot()
	snapshot.BlockDomains = []string{"ads.test"}
	snapshot.Domains = []DomainRule{
		{Kind: "exact", Value: "ads.test", Route: VPN},
		{Kind: "exact", Value: "blocked.test", Route: Direct},
		{Kind: "exact", Value: "chosen.test", Route: VPN},
		{Kind: "suffix", Value: "suffix.test", Route: VPN},
		{Kind: "keyword", Value: "media", Route: VPN},
		{Kind: "regex", Value: `^rx[0-9]+\.test$`, Route: VPN},
		{Kind: "exact", Value: "blocked.test", Route: Block},
	}
	p, err := Compile(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	for _, fixture := range []struct {
		name string
		want Route
	}{
		{"chosen.test", VPN}, {"CHOSEN.TEST.", VPN}, {"sub.chosen.test", Direct},
		{"suffix.test", VPN}, {"sub.suffix.test", VPN}, {"evilsuffix.test", Direct},
		{"cdn.media.test", VPN}, {"rx12.test", VPN}, {"xrx12.test", Direct},
		{"ads.test", Block}, {"sub.ads.test", Block}, {"blocked.test", Block},
		{"unknown.test", Direct}, {"printer", Local}, {"printer.local", Local},
		{"1.0.0.127.in-addr.arpa", Local}, {"1.ip6.arpa", Local},
		{"api4.ipify.org", VPN}, {"www.cloudflare.com", VPN},
	} {
		if got := p.Decision(fixture.name); got != fixture.want {
			t.Errorf("%s: got %s want %s", fixture.name, got, fixture.want)
		}
	}
	snapshot.Mode = "all"
	p, err = Compile(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if p.Decision("unknown.test") != VPN || p.Decision("sub.ads.test") != Block {
		t.Fatal("full mode altered explicit block priority")
	}
}

func TestAdmissionRejectsUnsupportedPoliciesWithoutEchoingSecrets(t *testing.T) {
	for _, mutate := range []func(*Snapshot){
		func(s *Snapshot) { s.Mode = "caller-controlled-runtime" },
		func(s *Snapshot) { s.SelectedNodeID = "missing" },
		func(s *Snapshot) { s.Nodes = append(s.Nodes, s.Nodes[0]) },
		func(s *Snapshot) { s.Domains = []DomainRule{{Kind: "unknown", Value: "private-token", Route: VPN}} },
		func(s *Snapshot) { s.Domains = []DomainRule{{Kind: "regex", Value: "[private-token", Route: VPN}} },
		func(s *Snapshot) { s.BlockDomains = []string{"BAD.test"} },
		func(s *Snapshot) { s.IPs = []IPRule{{Prefix: "192.0.2.1/24", Route: VPN}} },
		func(s *Snapshot) { s.SubscriptionURL = "http://private-token.test/subscription" },
	} {
		s := testSnapshot()
		mutate(&s)
		_, err := Compile(s)
		if !errors.Is(err, ErrInvalid) || strings.Contains(err.Error(), "private-token") {
			t.Fatalf("unsafe admission result: %v", err)
		}
	}
}

func TestParseNodeSupportsAdmittedVLESSTransports(t *testing.T) {
	for _, fixture := range []struct{ name, network, security, flow string }{
		{"raw", "tcp", "none", ""}, {"tls", "raw", "tls", ""}, {"ws", "ws", "tls", ""}, {"grpc", "grpc", "tls", ""},
		{"reality", "raw", "reality", "xtls-rprx-vision"}, {"xhttp-tls", "xhttp", "tls", ""}, {"xhttp-reality", "splithttp", "reality", ""},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			u, _ := url.Parse(testNodeURI)
			q := u.Query()
			q.Set("type", fixture.network)
			q.Set("security", fixture.security)
			q.Set("sni", "server.test")
			q.Set("path", "/vpn")
			q.Set("serviceName", "vpn")
			if fixture.flow != "" {
				q.Set("flow", fixture.flow)
			}
			if fixture.security == "reality" {
				q.Set("pbk", strings.Repeat("A", 43))
				q.Set("sid", "0123456789abcdef")
			}
			u.RawQuery = q.Encode()
			host, outbound, err := ParseNode(Node{ID: "node-1", URI: u.String()})
			if err != nil || host != "server.test" {
				t.Fatalf("admitted transport rejected: %v", err)
			}
			encoded, _ := json.Marshal(outbound)
			for _, forbidden := range []string{`"env"`, `"downloadSettings"`, `"sendThrough"`, `"dialerProxy"`} {
				if strings.Contains(string(encoded), forbidden) {
					t.Fatalf("derived config acquired %s", forbidden)
				}
			}
		})
	}
}

func TestParseNodeAdmitsLibXrayShareFormats(t *testing.T) {
	id := "11111111-1111-1111-1111-111111111111"
	shadowsocks := "ss://" + base64.StdEncoding.EncodeToString([]byte("aes-128-gcm:password")) + "@ss.example:8388#Shadowsocks"
	socks := "socks://" + base64.StdEncoding.EncodeToString([]byte("socksuser:sockspass")) + "@socks.example:1080"
	for _, fixture := range []struct{ link, host, protocol string }{
		{"vmess://" + id + "@vmess.example:443?encryption=auto#VMess", "vmess.example", "vmess"},
		{"trojan://secret@trojan.example:443?sni=trojan.example#Trojan", "trojan.example", "trojan"},
		{shadowsocks, "ss.example", "shadowsocks"},
		{socks, "socks.example", "socks"},
		{"hysteria2://auth@hy2.example:443?sni=hy2.example#Hysteria", "hy2.example", "hysteria"},
		{"hy2://auth@hop.example:443,8443?sni=hop.example#Hop", "hop.example", "hysteria"},
		{"vless://" + id + "@server.test:443?encryption=none&type=xhttp&mode=stream-up&extra=" + url.QueryEscape(`{"xPaddingBytes":"100-1000","noGRPCHeader":false}`), "server.test", "vless"},
	} {
		host, outbound, err := ParseNode(Node{ID: "node-1", URI: fixture.link})
		if err != nil || host != fixture.host || outbound["protocol"] != fixture.protocol || outbound["tag"] != "vpn" {
			t.Fatalf("%s: host %q protocol %v err %v", fixture.protocol, host, outbound["protocol"], err)
		}
		encoded, _ := json.Marshal(outbound)
		for _, forbidden := range []string{`"env"`, `"downloadSettings"`, `"sendThrough"`, `"dialerProxy"`, `"sockopt"`} {
			if strings.Contains(string(encoded), forbidden) {
				t.Fatalf("%s acquired %s", fixture.protocol, forbidden)
			}
		}
	}
}

func TestBuildReplacesShareAddressWithResolvedIP(t *testing.T) {
	snapshot := testSnapshot()
	snapshot.Nodes[0].URI = "trojan://secret@trojan.example:443?sni=trojan.example"
	compiled, err := Compile(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	artifacts, err := compiled.Build(ConfigOptions{Interface: "en0", TUN: "utun900", ServerIP: "203.0.113.10"})
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if json.Unmarshal(artifacts.Config, &config) != nil {
		t.Fatal("invalid config")
	}
	var vpn map[string]any
	for _, raw := range config["outbounds"].([]any) {
		outbound := raw.(map[string]any)
		if outbound["tag"] == "vpn" {
			vpn = outbound
		}
	}
	settings := vpn["settings"].(map[string]any)
	stream := vpn["streamSettings"].(map[string]any)
	tls := stream["tlsSettings"].(map[string]any)
	sockopt := stream["sockopt"].(map[string]any)
	if settings["address"] != "203.0.113.10" || tls["serverName"] != "trojan.example" || sockopt["interface"] != "en0" {
		t.Fatalf("resolved dial address was not separated from the server name: %s", artifacts.Config)
	}
}

func TestParseNodeRejectsShareContainersAndLegacyVMess(t *testing.T) {
	secret := "private-token"
	legacy := "vmess://" + base64.StdEncoding.EncodeToString([]byte(`{"add":"`+secret+`","port":"443","id":"11111111-1111-1111-1111-111111111111","net":"tcp"}`))
	for _, uri := range []string{
		legacy,
		`{"outbounds":[{"protocol":"freedom","tag":"` + secret + `"}]}`,
		"hysteria://" + secret + "@example.com:443",
		"vless://11111111-1111-1111-1111-111111111111:extra@server.test:443?encryption=none",
		"vless://11111111-1111-1111-1111-111111111111@server.test:443?encryption=none\nvless://11111111-1111-1111-1111-111111111111@other.test:443?encryption=none",
	} {
		_, _, err := ParseNode(Node{ID: "node-1", URI: uri})
		if !errors.Is(err, ErrInvalid) || strings.Contains(err.Error(), secret) {
			t.Fatalf("unsafe share rejection: %v", err)
		}
	}
}

func TestParseNodeRejectsPathsEnvironmentAndNestedDialers(t *testing.T) {
	for _, fixture := range []struct{ key, value string }{
		{"env", "private-token"}, {"config", "/tmp/private-token"}, {"sendThrough", "127.0.0.1"},
		{"extra", `{"downloadSettings":{"address":"private-token.test"}}`},
		{"extra", `{"sockopt":{"interface":"private-token"}}`},
		{"extra", `{"xmux":{"dialerProxy":"private-token"}}`},
	} {
		u, _ := url.Parse(testNodeURI)
		q := u.Query()
		q.Set("type", "xhttp")
		q.Set(fixture.key, fixture.value)
		u.RawQuery = q.Encode()
		_, _, err := ParseNode(Node{ID: "node-1", URI: u.String()})
		if !errors.Is(err, ErrInvalid) || strings.Contains(err.Error(), "private-token") {
			t.Fatalf("unsafe node rejection for %s: %v", fixture.key, err)
		}
	}
}
