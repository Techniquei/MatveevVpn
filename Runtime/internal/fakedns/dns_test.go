package fakedns

import (
	"context"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/miekg/dns"
)

type responseWriter struct{ answer *dns.Msg }

func (*responseWriter) LocalAddr() net.Addr           { return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)} }
func (*responseWriter) RemoteAddr() net.Addr          { return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)} }
func (w *responseWriter) WriteMsg(msg *dns.Msg) error { w.answer = msg.Copy(); return nil }
func (*responseWriter) Write([]byte) (int, error)     { panic("unused") }
func (*responseWriter) Close() error                  { return nil }
func (*responseWriter) TsigStatus() error             { return nil }
func (*responseWriter) TsigTimersOnly(bool)           {}
func (*responseWriter) Hijack()                       {}

func ask(h *Handler, name string, kind uint16) *dns.Msg {
	w := new(responseWriter)
	query := new(dns.Msg)
	query.SetQuestion(name, kind)
	h.ServeDNS(w, query)
	return w.answer
}

func TestPublicAndLocalDNSPolicy(t *testing.T) {
	s := openTestStore(t)
	var routed []Action
	h := &Handler{Store: s, Decision: func(name string) Action {
		switch name {
		case "ads.example":
			return Block
		case "direct.example":
			return Direct
		case "lan.example":
			return Local
		default:
			return VPN
		}
	}, Resolve: func(ctx context.Context, query *dns.Msg, action Action) (*dns.Msg, error) {
		routed = append(routed, action)
		answer := new(dns.Msg)
		answer.SetReply(query)
		answer.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: query.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60}, A: net.IPv4(10, 0, 0, 2)}}
		return answer, nil
	}}
	if err := h.Activate(1); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"vpn.example.", "direct.example."} {
		answer := ask(h, name, dns.TypeA)
		if answer.Rcode != dns.RcodeSuccess || len(answer.Answer) != 1 {
			t.Fatal("public address missing")
		}
		addr := answer.Answer[0].(*dns.A).A.String()
		if addr[:7] != "198.18." {
			t.Fatal("real public answer escaped")
		}
		if answer := ask(h, name, dns.TypeAAAA); answer.Rcode != dns.RcodeSuccess || len(answer.Answer) != 0 {
			t.Fatal("public IPv6 escaped")
		}
	}
	if answer := ask(h, "ads.example.", dns.TypeA); answer.Rcode != dns.RcodeNameError {
		t.Fatal("block not NXDOMAIN")
	}
	for _, name := range []string{"printer.local.", "lan.example."} {
		answer := ask(h, name, dns.TypeA)
		if answer.Rcode != dns.RcodeSuccess || answer.Answer[0].(*dns.A).A.String() != "10.0.0.2" {
			t.Fatal("local query synthesized")
		}
	}
	if len(routed) != 2 || routed[0] != Local || routed[1] != Local {
		t.Fatal("upstream decision ignored")
	}
	if answer := ask(h, "vpn.example.", dns.TypeANY); answer.Rcode != dns.RcodeNotImplemented {
		t.Fatal("ANY address bypass permitted")
	}
}

func TestHTTPSHintsAndUnknownOperators(t *testing.T) {
	s := openTestStore(t)
	rr, err := dns.NewRR("example.com. 60 IN HTTPS 1 . mandatory=alpn,ipv4hint,ipv6hint alpn=h2 ipv4hint=1.2.3.4 ipv6hint=2001:db8::1")
	if err != nil {
		t.Fatal(err)
	}
	h := &Handler{Store: s, Resolve: func(ctx context.Context, query *dns.Msg, _ Action) (*dns.Msg, error) {
		answer := new(dns.Msg)
		answer.SetReply(query)
		answer.Answer = []dns.RR{rr}
		answer.Extra = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: "example.com.", Rrtype: dns.TypeA, Class: dns.ClassINET}, A: net.IPv4(1, 2, 3, 4)}}
		answer.AuthenticatedData = true
		return answer, nil
	}}
	_ = h.Activate(1)
	answer := ask(h, "example.com.", dns.TypeHTTPS)
	if answer.Rcode != dns.RcodeSuccess || len(answer.Answer) != 1 || len(answer.Extra) != 0 || answer.AuthenticatedData {
		t.Fatal("unsafe binding answer")
	}
	binding := answer.Answer[0].(*dns.HTTPS)
	for _, value := range binding.Value {
		if value.Key() == dns.SVCB_IPV4HINT || value.Key() == dns.SVCB_IPV6HINT {
			t.Fatal("hints preserved")
		}
		if mandatory, ok := value.(*dns.SVCBMandatory); ok && (len(mandatory.Code) != 1 || mandatory.Code[0] != dns.SVCB_ALPN) {
			t.Fatal("mandatory still references stripped hints")
		}
	}
	rr, err = dns.NewRR("example.com. 60 IN HTTPS 1 . key65400=opaque")
	if err != nil {
		t.Fatal(err)
	}
	if answer := ask(h, "example.com.", dns.TypeHTTPS); answer.Rcode != dns.RcodeServerFailure {
		t.Fatal("unknown binding operator admitted")
	}
}

func TestSuspendPreventsOldRevisionResponses(t *testing.T) {
	s := openTestStore(t)
	started := make(chan struct{})
	release := make(chan struct{})
	h := &Handler{Store: s, Resolve: func(ctx context.Context, query *dns.Msg, _ Action) (*dns.Msg, error) {
		close(started)
		<-release
		answer := new(dns.Msg)
		answer.SetReply(query)
		return answer, nil
	}}
	_ = h.Activate(7)
	completed := make(chan *dns.Msg, 1)
	go func() { completed <- ask(h, "example.com.", dns.TypeTXT) }()
	<-started
	h.Suspend()
	if h.Revision() != 0 {
		t.Fatal("suspend retained active revision")
	}
	_ = h.Activate(8)
	close(release)
	if answer := <-completed; answer.Rcode != dns.RcodeServerFailure {
		t.Fatal("old revision answer published after switch")
	}
	h.Suspend()
	if answer := ask(h, "example.com.", dns.TypeA); answer.Rcode != dns.RcodeServerFailure {
		t.Fatal("DNS answered while suspended")
	}
}

func TestDeadlineAndHungResolverConcurrencyBound(t *testing.T) {
	s := openTestStore(t)
	started := make(chan struct{}, 1)
	release := make(chan struct{})
	h := &Handler{Store: s, Timeout: 30 * time.Millisecond, MaxConcurrent: 1, Resolve: func(ctx context.Context, query *dns.Msg, _ Action) (*dns.Msg, error) {
		started <- struct{}{}
		<-release
		answer := new(dns.Msg)
		answer.SetReply(query)
		return answer, nil
	}}
	_ = h.Activate(1)
	begin := time.Now()
	if answer := ask(h, "one.example.", dns.TypeTXT); answer.Rcode != dns.RcodeServerFailure {
		t.Fatal("hung resolver accepted")
	}
	if time.Since(begin) > time.Second {
		t.Fatal("query deadline not bounded")
	}
	<-started
	for i := 0; i < 100; i++ {
		if answer := ask(h, "two.example.", dns.TypeTXT); answer.Rcode != dns.RcodeServerFailure {
			t.Fatal("concurrency cap ignored")
		}
	}
	if len(started) != 0 {
		t.Fatal("additional stuck resolver started")
	}
	close(release)
}

func TestLoopbackTCPAndUDPAndListenerCleanup(t *testing.T) {
	s := openTestStore(t)
	h := &Handler{Store: s}
	_ = h.Activate(1)
	server, err := StartServer("127.0.0.1:0", h)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	for _, transport := range []string{"udp", "tcp"} {
		client := &dns.Client{Net: transport, Timeout: time.Second}
		query := new(dns.Msg)
		query.SetQuestion("bound.example.", dns.TypeA)
		answer, _, err := client.Exchange(query, server.Address())
		if err != nil || answer.Rcode != dns.RcodeSuccess || len(answer.Answer) != 1 {
			t.Fatalf("%s failed: %v", transport, err)
		}
	}
	_ = server.Close()
	listener, err := net.Listen("tcp", server.Address())
	if err != nil {
		t.Fatal("TCP listener not released")
	}
	_ = listener.Close()
	packet, err := net.ListenPacket("udp", server.Address())
	if err != nil {
		t.Fatal("UDP listener not released")
	}
	_ = packet.Close()
	for _, address := range []string{"0.0.0.0:0", ":53", "1.2.3.4:53", "localhost:53"} {
		if server, err := StartServer(address, h); err == nil {
			_ = server.Close()
			t.Fatal("public or ambiguous bind accepted")
		}
	}
}

func TestMalformedAndFatalTableFailClosed(t *testing.T) {
	s := openTestStore(t)
	h := &Handler{Store: s}
	_ = h.Activate(1)
	w := new(responseWriter)
	query := new(dns.Msg)
	query.SetQuestion("one.example.", dns.TypeA)
	query.Question = append(query.Question, query.Question[0])
	h.ServeDNS(w, query)
	if w.answer.Rcode != dns.RcodeFormatError {
		t.Fatal("multiple questions accepted")
	}
	s.failed.Store(true)
	if answer := ask(h, "existing.example.", dns.TypeAAAA); answer.Rcode != dns.RcodeServerFailure {
		t.Fatal("broken table still serving public policy")
	}
	if err := h.Activate(2); err == nil {
		t.Fatal("broken table activated")
	}
}

func TestConcurrentSuspendAndRequests(t *testing.T) {
	s := openTestStore(t)
	h := &Handler{Store: s}
	_ = h.Activate(1)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 8; j++ {
				_ = ask(h, "parallel.example.", dns.TypeA)
			}
		}()
	}
	for i := uint64(2); i < 10; i++ {
		h.Suspend()
		_ = h.Activate(i)
	}
	wg.Wait()
}

func TestPublicationStallCannotBlockDNSDeadlineOrSuspend(t *testing.T) {
	s := openTestStore(t)
	started, release := make(chan struct{}), make(chan struct{})
	original := s.publish
	s.publish = func(directory string, record mapping) error {
		close(started)
		<-release
		return original(directory, record)
	}
	h := &Handler{Store: s, Timeout: 30 * time.Millisecond}
	_ = h.Activate(1)
	completed := make(chan *dns.Msg, 1)
	go func() { completed <- ask(h, "stalled.example.", dns.TypeA) }()
	<-started
	select {
	case answer := <-completed:
		if answer.Rcode != dns.RcodeServerFailure {
			t.Fatal("stalled allocation answered")
		}
	case <-time.After(time.Second):
		close(release)
		t.Fatal("store health check blocked DNS timeout")
	}
	begin := time.Now()
	h.Suspend()
	if time.Since(begin) > time.Second {
		t.Fatal("suspend blocked on publication")
	}
	close(release)
}
