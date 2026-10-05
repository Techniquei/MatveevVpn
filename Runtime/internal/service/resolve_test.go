package service

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/miekg/dns"
	"matveevvpn/runtime/internal/fakedns"
	"matveevvpn/runtime/internal/network"
)

func dnsQuery(name string) *dns.Msg {
	query := new(dns.Msg)
	query.SetQuestion(name, dns.TypeA)
	return query
}

func dnsHTTPSFixture(t *testing.T, reply func(*dns.Msg) *dns.Msg) (*httptest.Server, *http.Client) {
	t.Helper()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.Header.Get("Content-Type") != "application/dns-message" || request.Header.Get("Cache-Control") != "no-store, no-cache" {
			t.Error("DoH request contract changed")
		}
		data, err := io.ReadAll(io.LimitReader(request.Body, maximumResolverBody+1))
		query := new(dns.Msg)
		if err != nil || query.Unpack(data) != nil {
			http.Error(w, "bad", 400)
			return
		}
		answer := reply(query)
		data, err = answer.Pack()
		if err != nil {
			t.Error(err)
			http.Error(w, "bad", 500)
			return
		}
		w.Header().Set("Content-Type", "application/dns-message")
		_, _ = w.Write(data)
	}))
	t.Cleanup(server.Close)
	return server, resolverClient(server.Client().Transport)
}

func TestDoHReplyValidationRoutingAndBootstrap(t *testing.T) {
	var directCalls, vpnCalls atomic.Int32
	directServer, direct := dnsHTTPSFixture(t, func(query *dns.Msg) *dns.Msg {
		directCalls.Add(1)
		answer := new(dns.Msg)
		answer.SetReply(query)
		answer.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: query.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 999999}, A: net.IPv4(203, 0, 113, 2)}}
		return answer
	})
	vpnServer, vpn := dnsHTTPSFixture(t, func(query *dns.Msg) *dns.Msg {
		vpnCalls.Add(1)
		answer := new(dns.Msg)
		answer.SetReply(query)
		return answer
	})
	r := &Resolver{direct: direct, vpn: vpn, dohURL: directServer.URL}
	answer, err := r.Resolve(context.Background(), dnsQuery("server.example."), fakedns.Direct)
	if err != nil || answer.Answer[0].Header().Ttl != 300 {
		t.Fatal("DoH failed or TTL unbounded")
	}
	addresses, err := r.Bootstrap(context.Background(), "server.example")
	if err != nil || len(addresses) != 1 || addresses[0] != "203.0.113.2" {
		t.Fatal("bootstrap failed")
	}
	r.dohURL = vpnServer.URL
	if _, err := r.Resolve(context.Background(), dnsQuery("vpn.example."), fakedns.VPN); err != nil {
		t.Fatal(err)
	}
	if directCalls.Load() != 2 || vpnCalls.Load() != 1 {
		t.Fatal("DNS upstream action ignored")
	}
	if _, err := r.Resolve(context.Background(), dnsQuery("blocked.example."), fakedns.Block); !errors.Is(err, ErrResolver) {
		t.Fatal("blocked query sent upstream")
	}
	for _, host := range []string{"198.18.0.4", "127.0.0.1", "::1", "0.0.0.0"} {
		if _, err := r.Bootstrap(context.Background(), host); err == nil {
			t.Fatal("invalid uplink accepted")
		}
	}
	before := directCalls.Load()
	if addresses, err := r.Bootstrap(context.Background(), "192.0.2.3"); err != nil || addresses[0] != "192.0.2.3" {
		t.Fatal(err)
	}
	if directCalls.Load() != before {
		t.Fatal("numeric bootstrap performed DNS")
	}
}

func TestDoHRejectsMismatchOversizeAndTLSFailure(t *testing.T) {
	for _, mismatch := range []string{"id", "name", "type", "truncated"} {
		t.Run(mismatch, func(t *testing.T) {
			server, client := dnsHTTPSFixture(t, func(query *dns.Msg) *dns.Msg {
				answer := new(dns.Msg)
				answer.SetReply(query)
				switch mismatch {
				case "id":
					answer.Id++
				case "name":
					answer.Question[0].Name = "other.example."
				case "type":
					answer.Question[0].Qtype = dns.TypeAAAA
				case "truncated":
					answer.Truncated = true
				}
				return answer
			})
			r := &Resolver{direct: client, dohURL: server.URL}
			if _, err := r.Resolve(context.Background(), dnsQuery("expected.example."), fakedns.Direct); err == nil {
				t.Fatal("mismatched reply accepted")
			}
		})
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/dns-message")
		_, _ = io.WriteString(w, strings.Repeat("x", maximumResolverBody+1))
	}))
	defer server.Close()
	r := &Resolver{direct: resolverClient(server.Client().Transport), dohURL: server.URL}
	if _, err := r.Resolve(context.Background(), dnsQuery("expected.example."), fakedns.Direct); err == nil {
		t.Fatal("oversized DNS accepted")
	}
	r.direct = resolverClient(&http.Transport{})
	if _, err := r.Resolve(context.Background(), dnsQuery("expected.example."), fakedns.Direct); err == nil {
		t.Fatal("untrusted TLS certificate accepted")
	}
}

func TestCapturedLocalResolverAndTruncatedTCPRetry(t *testing.T) {
	udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	tcp, err := net.Listen("tcp4", udp.LocalAddr().String())
	if err != nil {
		_ = udp.Close()
		t.Fatal(err)
	}
	var tcpCalls atomic.Int32
	answer := dns.HandlerFunc(func(w dns.ResponseWriter, query *dns.Msg) {
		response := new(dns.Msg)
		response.SetReply(query)
		if _, ok := w.RemoteAddr().(*net.UDPAddr); ok {
			response.Truncated = true
		} else {
			tcpCalls.Add(1)
			response.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: query.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 20}, A: net.IPv4(10, 0, 0, 20)}}
		}
		_ = w.WriteMsg(response)
	})
	started := make(chan struct{}, 2)
	servers := []*dns.Server{{PacketConn: udp, Handler: answer, NotifyStartedFunc: func() { started <- struct{}{} }}, {Listener: tcp, Handler: answer, NotifyStartedFunc: func() { started <- struct{}{} }}}
	for _, server := range servers {
		go func(server *dns.Server) { _ = server.ActivateAndServe() }(server)
		defer server.Shutdown()
	}
	<-started
	<-started
	var bound atomic.Int32
	r := &Resolver{servers: []string{udp.LocalAddr().String()}, control: func(network, address string, _ syscall.RawConn) error {
		if network != "udp4" && network != "tcp4" {
			t.Error("wrong bindfamily")
		}
		bound.Add(1)
		return nil
	}}
	reply, err := r.Resolve(context.Background(), dnsQuery("printer.local."), fakedns.Local)
	if err != nil || len(reply.Answer) != 1 || reply.Answer[0].(*dns.A).A.String() != "10.0.0.20" || tcpCalls.Load() != 1 || bound.Load() != 2 {
		t.Fatalf("local fallbackfailed: %v", err)
	}
	r.servers = nil
	if _, err := r.Resolve(context.Background(), dnsQuery("printer.local."), fakedns.Local); err == nil {
		t.Fatal("missingcapturedDNS usedsystemfallback")
	}
}

func TestResolverTransportBoundsAndNoProxy(t *testing.T) {
	control := func(string, string, syscall.RawConn) error { return nil }
	r, err := newResolver(network.Physical{Interface: "en0", DNS: []string{"192.0.2.53"}}, control)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	for _, transport := range r.transports {
		if transport.Proxy != nil || !transport.DisableKeepAlives || transport.TLSClientConfig.InsecureSkipVerify || transport.MaxResponseHeaderBytes == 0 {
			t.Fatal("transport boundaryweakened")
		}
	}
	if r.direct == r.vpn || r.direct == r.health {
		t.Fatal("direct/tunnel boundary merged")
	}
	for _, servers := range [][]string{{"127.0.0.1"}, {"localhost"}, {"0.0.0.0"}} {
		if candidate, err := newResolver(network.Physical{Interface: "en0", DNS: servers}, control); err == nil {
			candidate.Close()
			t.Fatal("recursive/nonnumericcapturedresolver admitted")
		}
	}
}

func TestHTTPSHealthFreshBoundedAndIndependent(t *testing.T) {
	var noncesMu sync.Mutex
	nonces := make(map[string]bool)
	var connections atomic.Int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		nonce := request.URL.Query().Get("matveevvpn_nonce")
		if nonce == "" || request.Header.Get("Cache-Control") != "no-cache, no-store" || request.Header.Get("Pragma") != "no-cache" {
			t.Error("healthcanbecached")
		}
		noncesMu.Lock()
		if nonces[nonce] {
			t.Error("noncereused")
		}
		nonces[nonce] = true
		noncesMu.Unlock()
		_, _ = io.WriteString(w, "203.0.113.2")
	}))
	server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			connections.Add(1)
		}
	}
	server.StartTLS()
	defer server.Close()
	transport := server.Client().Transport.(*http.Transport).Clone()
	transport.DisableKeepAlives = true
	r := &Resolver{health: resolverClient(transport), healthURLs: []string{server.URL + "/one", server.URL + "/two"}}
	for i := 0; i < 2; i++ {
		if err := r.Probe(context.Background(), false); err != nil {
			t.Fatal(err)
		}
	}
	if connections.Load() < 2 {
		t.Fatal("healthreusedoldconnection")
	}
	bad := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(500) }))
	defer bad.Close()
	// A single independent success is enough even when the otherendpointfailsTLS.
	r.healthURLs = []string{bad.URL, server.URL}
	if err := r.Probe(context.Background(), false); err != nil {
		t.Fatal("oneendpointfailuretookdownhealthyTUN")
	}
	r.healthURLs = []string{bad.URL}
	if err := r.Probe(context.Background(), false); err == nil {
		t.Fatal("failedHTTPSreportedhealthy")
	}
}

func TestHealthRejectsOversizeRedirectAndHonorsCancellation(t *testing.T) {
	for _, kind := range []string{"oversize", "redirect", "timeout"} {
		t.Run(kind, func(t *testing.T) {
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
				switch kind {
				case "oversize":
					_, _ = io.WriteString(w, strings.Repeat("x", maximumResolverBody+1))
				case "redirect":
					http.Redirect(w, request, "/other", 302)
				case "timeout":
					<-request.Context().Done()
				}
			}))
			defer server.Close()
			r := &Resolver{health: resolverClient(server.Client().Transport), healthURLs: []string{server.URL}}
			ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
			defer cancel()
			begin := time.Now()
			if err := r.Probe(ctx, false); err == nil {
				t.Fatal("badhealthaccepted")
			}
			if time.Since(begin) > time.Second {
				t.Fatal("healthcancellationnotbounded")
			}
		})
	}
}

func TestDirectHealthRequiresActualDoHTransfer(t *testing.T) {
	var calls atomic.Int32
	server, client := dnsHTTPSFixture(t, func(query *dns.Msg) *dns.Msg {
		calls.Add(1)
		if !strings.Contains(query.Question[0].Name, "matveevvpn.invalid") {
			t.Error("physicalhealthquerynotfresh")
		}
		answer := new(dns.Msg)
		answer.SetRcode(query, dns.RcodeNameError)
		return answer
	})
	r := &Resolver{direct: client, dohURL: server.URL}
	if err := r.Probe(context.Background(), true); err != nil || calls.Load() != 1 {
		t.Fatal("physicalhealthdidnottransferDNS")
	}
}

func TestTunnelProbeRejectsAPublicAddress(t *testing.T) {
	r := &Resolver{health: resolverClient(resolverTransport(nil, "")), healthURLs: []string{"https://api4.ipify.org/cdn-cgi/trace"}}
	r.SetTunnelAddress(func(host string) (netip.Addr, error) {
		if host != "api4.ipify.org" {
			t.Fatalf("probe host %s", host)
		}
		return netip.MustParseAddr("203.0.113.9"), nil
	})
	started := time.Now()
	if err := r.Probe(context.Background(), false); err == nil {
		t.Fatal("public address counted as a tunnel probe")
	}
	if time.Since(started) > 500*time.Millisecond {
		t.Fatal("public address was dialed")
	}
}

type failingRoundTripper struct{}

func (failingRoundTripper) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("physical path unavailable")
}

func TestTunnelBootstrapIsSeparateFromPhysicalBootstrap(t *testing.T) {
	server, vpn := dnsHTTPSFixture(t, func(query *dns.Msg) *dns.Msg {
		answer := new(dns.Msg)
		answer.SetReply(query)
		answer.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: query.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30}, A: net.IPv4(203, 0, 113, 9)}}
		return answer
	})
	r := &Resolver{direct: &http.Client{Transport: failingRoundTripper{}}, vpn: vpn, dohURL: server.URL}
	if _, err := r.Bootstrap(context.Background(), "server.example"); err == nil {
		t.Fatal("physical bootstrap used the tunnel resolver")
	}
	addresses, err := r.BootstrapThroughTunnel(context.Background(), "server.example")
	if err != nil || len(addresses) != 1 || addresses[0] != "203.0.113.9" {
		t.Fatal("tunnel bootstrap failed", addresses, err)
	}
}
