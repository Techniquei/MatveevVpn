package fakedns

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/miekg/dns"
)

type Action uint8

const (
	Block Action = iota
	Direct
	VPN
	Local
)

const maximumDNSBytes = 4096

type activePolicy struct {
	revision uint64
	decision func(string) Action
	resolve  func(context.Context, *dns.Msg, Action) (*dns.Msg, error)
	ctx      context.Context
	cancel   context.CancelFunc
}

type Handler struct {
	Store *Store
	// Configure callbacks before Activate; queries use an immutable callback
	// snapshot. Suspend before changing these fields for the next revision.
	Decision      func(string) Action
	Resolve       func(context.Context, *dns.Msg, Action) (*dns.Msg, error)
	Timeout       time.Duration
	MaxConcurrent int
	gate          sync.RWMutex
	active        *activePolicy
	once          sync.Once
	permits       chan struct{}
	timeout       time.Duration
}

func (h *Handler) initialize() {
	h.once.Do(func() {
		limit := h.MaxConcurrent
		if limit <= 0 || limit > 64 {
			limit = 64
		}
		h.permits = make(chan struct{}, limit)
		h.timeout = h.Timeout
		if h.timeout <= 0 || h.timeout > 2*time.Second {
			h.timeout = 2 * time.Second
		}
	})
}

func (h *Handler) Activate(revision uint64) error {
	h.initialize()
	h.gate.Lock()
	defer h.gate.Unlock()
	if h.Store == nil || h.Store.Err() != nil || revision == 0 {
		return ErrTable
	}
	if h.active != nil {
		h.active.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	h.active = &activePolicy{revision: revision, decision: h.Decision, resolve: h.Resolve, ctx: ctx, cancel: cancel}
	return nil
}

// Suspend waits only for bounded response writes, never for DNS upstream work.
// Once it returns, no answer from the previous revision can be published.
func (h *Handler) Suspend() {
	h.gate.Lock()
	if h.active != nil {
		h.active.cancel()
	}
	h.active = nil
	h.gate.Unlock()
}

func (h *Handler) Revision() uint64 {
	h.gate.RLock()
	defer h.gate.RUnlock()
	if h.active == nil {
		return 0
	}
	return h.active.revision
}

func failure(query *dns.Msg, code int) *dns.Msg {
	answer := new(dns.Msg)
	answer.SetRcode(query, code)
	answer.RecursionAvailable = true
	return answer
}

func (h *Handler) ServeDNS(writer dns.ResponseWriter, query *dns.Msg) {
	h.initialize()
	h.gate.RLock()
	policy := h.active
	h.gate.RUnlock()
	answer := failure(query, dns.RcodeServerFailure)
	if query.Len() > maximumDNSBytes || query.Opcode != dns.OpcodeQuery || len(query.Question) != 1 || query.Question[0].Qclass != dns.ClassINET {
		answer = failure(query, dns.RcodeFormatError)
	} else if policy != nil && h.Store != nil && h.Store.Err() == nil {
		select {
		case h.permits <- struct{}{}:
			ctx, cancel := context.WithTimeout(policy.ctx, h.timeout)
			completed := make(chan *dns.Msg, 1)
			// A resolver ignoring cancellation retains its permit, so subsequent
			// queries cannot create an unbounded number of stuck goroutines.
			go func() {
				defer func() { <-h.permits }()
				completed <- h.answer(ctx, query.Copy(), policy)
			}()
			select {
			case answer = <-completed:
			case <-ctx.Done():
			}
			cancel()
		default:
		}
	}
	h.gate.RLock()
	defer h.gate.RUnlock()
	if policy == nil || policy != h.active || h.Store == nil || h.Store.Err() != nil {
		answer = failure(query, dns.RcodeServerFailure)
	}
	answer.AuthenticatedData = false
	if _, ok := writer.RemoteAddr().(*net.UDPAddr); ok {
		size := 512
		if opt := query.IsEdns0(); opt != nil {
			size = int(opt.UDPSize())
			if size < 512 {
				size = 512
			}
			if size > 1232 {
				size = 1232
			}
		}
		answer.Truncate(size)
	}
	_ = writer.WriteMsg(answer)
}

func (h *Handler) answer(ctx context.Context, query *dns.Msg, policy *activePolicy) *dns.Msg {
	question := query.Question[0]
	name, err := normalizeDomain(question.Name)
	if err != nil {
		return failure(query, dns.RcodeFormatError)
	}
	action := VPN
	if policy.decision != nil {
		action = policy.decision(name)
	}
	if strings.HasSuffix(name, ".local") || strings.HasSuffix(name, ".home.arpa") || !strings.Contains(name, ".") {
		action = Local
	}
	if action > Local {
		return failure(query, dns.RcodeServerFailure)
	}
	if action == Block {
		return failure(query, dns.RcodeNameError)
	}
	if action != Local {
		switch question.Qtype {
		case dns.TypeA:
			addr, err := h.Store.Allocate(name)
			if err != nil {
				return failure(query, dns.RcodeServerFailure)
			}
			answer := failure(query, dns.RcodeSuccess)
			answer.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: question.Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60}, A: net.IP(addr.AsSlice())}}
			return answer
		case dns.TypeAAAA:
			return failure(query, dns.RcodeSuccess)
		case dns.TypeANY, dns.TypeAXFR, dns.TypeIXFR:
			return failure(query, dns.RcodeNotImplemented)
		}
	}
	if policy.resolve == nil {
		return failure(query, dns.RcodeServerFailure)
	}
	answer, err := policy.resolve(ctx, query, action)
	if err != nil || answer == nil || answer.Len() > maximumDNSBytes {
		return failure(query, dns.RcodeServerFailure)
	}
	answer = answer.Copy()
	answer.Id = query.Id
	answer.Question = append([]dns.Question(nil), query.Question...)
	answer.Response = true
	answer.AuthenticatedData = false
	if action != Local {
		var ok bool
		if answer.Answer, ok = sanitize(answer.Answer); !ok {
			return failure(query, dns.RcodeServerFailure)
		}
		if answer.Ns, ok = sanitize(answer.Ns); !ok {
			return failure(query, dns.RcodeServerFailure)
		}
		if answer.Extra, ok = sanitize(answer.Extra); !ok {
			return failure(query, dns.RcodeServerFailure)
		}
	}
	return answer
}

func sanitize(records []dns.RR) ([]dns.RR, bool) {
	filtered := make([]dns.RR, 0, len(records))
	for _, rr := range records {
		switch record := rr.(type) {
		case *dns.A, *dns.AAAA, *dns.RRSIG:
			// Additional real addresses can otherwise bypass subsequent FakeDNS
			// lookups. Rewriting answers also invalidates upstream signatures.
			continue
		case *dns.SVCB:
			if !sanitizeBinding(record) {
				return nil, false
			}
		case *dns.HTTPS:
			if !sanitizeBinding(&record.SVCB) {
				return nil, false
			}
		}
		filtered = append(filtered, rr)
	}
	return filtered, true
}

func sanitizeBinding(binding *dns.SVCB) bool {
	values := make([]dns.SVCBKeyValue, 0, len(binding.Value))
	for _, value := range binding.Value {
		switch value.Key() {
		case dns.SVCB_IPV4HINT, dns.SVCB_IPV6HINT:
			continue
		case dns.SVCB_MANDATORY:
			mandatory, ok := value.(*dns.SVCBMandatory)
			if !ok {
				return false
			}
			keys := make([]dns.SVCBKey, 0, len(mandatory.Code))
			for _, key := range mandatory.Code {
				if key > dns.SVCB_OHTTP {
					return false
				}
				if key != dns.SVCB_IPV4HINT && key != dns.SVCB_IPV6HINT {
					keys = append(keys, key)
				}
			}
			if len(keys) != 0 {
				mandatory.Code = keys
				values = append(values, mandatory)
			}
			continue
		case dns.SVCB_ALPN, dns.SVCB_NO_DEFAULT_ALPN, dns.SVCB_PORT, dns.SVCB_ECHCONFIG, dns.SVCB_DOHPATH, dns.SVCB_OHTTP:
		default:
			return false
		}
		values = append(values, value)
	}
	binding.Value = values
	return true
}

type Server struct {
	address  string
	tcp, udp *dns.Server
	mu       sync.Mutex
	err      error
	once     sync.Once
}

// StartServer binds only a numeric loopback address; port zero is for tests.
// Both transports use the same endpoint and have independent bounded I/O.
func StartServer(address string, handler *Handler) (*Server, error) {
	host, port, err := net.SplitHostPort(address)
	ip, parseErr := netip.ParseAddr(host)
	portNumber, portErr := strconv.Atoi(port)
	if err != nil || parseErr != nil || !ip.IsLoopback() || portErr != nil || portNumber < 0 || portNumber > 65535 || handler == nil {
		return nil, errors.New("dns_invalid_listener")
	}
	network := "tcp4"
	udpNetwork := "udp4"
	if ip.Is6() {
		network, udpNetwork = "tcp6", "udp6"
	}
	listener, err := net.Listen(network, address)
	if err != nil {
		return nil, errors.New("dns_listener_failed")
	}
	packet, err := net.ListenPacket(udpNetwork, listener.Addr().String())
	if err != nil {
		_ = listener.Close()
		return nil, errors.New("dns_listener_failed")
	}
	s := &Server{address: listener.Addr().String()}
	s.tcp = &dns.Server{Listener: &boundedListener{Listener: listener, limit: make(chan struct{}, 64)}, Handler: handler, ReadTimeout: 2 * time.Second, WriteTimeout: 2 * time.Second, IdleTimeout: func() time.Duration { return 2 * time.Second }, MaxTCPQueries: 16}
	s.udp = &dns.Server{PacketConn: packet, Handler: handler, UDPSize: maximumDNSBytes, ReadTimeout: 2 * time.Second, WriteTimeout: 2 * time.Second}
	started := make(chan struct{}, 2)
	s.tcp.NotifyStartedFunc = func() { started <- struct{}{} }
	s.udp.NotifyStartedFunc = func() { started <- struct{}{} }
	for _, server := range []*dns.Server{s.tcp, s.udp} {
		go func(server *dns.Server) {
			if err := server.ActivateAndServe(); err != nil {
				s.mu.Lock()
				s.err = errors.New("dns_listener_failed")
				s.mu.Unlock()
			}
		}(server)
	}
	deadline := time.NewTimer(2 * time.Second)
	defer deadline.Stop()
	for count := 0; count < 2; count++ {
		select {
		case <-started:
		case <-deadline.C:
			_ = listener.Close()
			_ = packet.Close()
			_ = s.Close()
			return nil, errors.New("dns_listener_failed")
		}
	}
	return s, nil
}

func (s *Server) Address() string { return s.address }

func (s *Server) Err() error { s.mu.Lock(); defer s.mu.Unlock(); return s.err }

func (s *Server) Close() error {
	s.once.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		var wait sync.WaitGroup
		for _, server := range []*dns.Server{s.tcp, s.udp} {
			wait.Add(1)
			go func(server *dns.Server) { defer wait.Done(); _ = server.ShutdownContext(ctx) }(server)
		}
		wait.Wait()
	})
	return nil
}

type boundedListener struct {
	net.Listener
	limit chan struct{}
}

func (l *boundedListener) Accept() (net.Conn, error) {
	for {
		conn, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		select {
		case l.limit <- struct{}{}:
			return &boundedConn{Conn: conn, limit: l.limit}, nil
		default:
			_ = conn.Close()
		}
	}
}

type boundedConn struct {
	net.Conn
	limit  chan struct{}
	closed atomic.Bool
}

func (c *boundedConn) Close() error {
	if c.closed.CompareAndSwap(false, true) {
		defer func() { <-c.limit }()
		return c.Conn.Close()
	}
	return nil
}
