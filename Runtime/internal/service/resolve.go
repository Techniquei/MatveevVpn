package service

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"syscall"
	"time"

	"github.com/miekg/dns"
	"matveevvpn/runtime/internal/fakedns"
	"matveevvpn/runtime/internal/network"
)

const dohEndpoint = "https://1.1.1.1/dns-query"
const maximumResolverBody = 4096

var ErrResolver = errors.New("resolver_failed")
var ErrHealth = errors.New("health_check_failed")

type Resolver struct {
	direct, vpn, health *http.Client
	transports          []*http.Transport
	servers             []string
	control             func(string, string, syscall.RawConn) error
	interfaceName       string
	dohURL              string
	healthURLs          []string
	tunnelAddress       func(string) (netip.Addr, error)
}

func NewResolver(physical network.Physical) (*Resolver, error) {
	control, err := network.PhysicalBind(physical.Interface)
	if err != nil {
		return nil, ErrResolver
	}
	return newResolver(physical, control)
}

func newResolver(physical network.Physical, control func(string, string, syscall.RawConn) error) (*Resolver, error) {
	if control == nil || physical.Interface == "" || len(physical.DNS) > 8 {
		return nil, ErrResolver
	}
	r := &Resolver{control: control, interfaceName: physical.Interface, dohURL: dohEndpoint, healthURLs: []string{"https://api4.ipify.org", "https://www.cloudflare.com/cdn-cgi/trace"}}
	for _, server := range physical.DNS {
		ip, err := netip.ParseAddr(server)
		// A previous loopback override must never recurse into this service.
		if err != nil || ip.IsUnspecified() || ip.IsMulticast() || ip.IsLoopback() || (ip.Zone() != "" && ip.Zone() != physical.Interface) {
			return nil, ErrResolver
		}
		if ip.IsLinkLocalUnicast() && ip.Is6() && ip.Zone() == "" {
			ip = ip.WithZone(physical.Interface)
		}
		r.servers = append(r.servers, net.JoinHostPort(ip.String(), "53"))
	}
	direct := resolverTransport(control, "cloudflare-dns.com")
	vpn := resolverTransport(nil, "cloudflare-dns.com")
	health := resolverTransport(nil, "")
	r.transports = []*http.Transport{direct, vpn, health}
	r.direct, r.vpn, r.health = resolverClient(direct), resolverClient(vpn), resolverClient(health)
	return r, nil
}

func resolverTransport(control func(string, string, syscall.RawConn) error, serverName string) *http.Transport {
	dialer := &net.Dialer{Timeout: 2 * time.Second, KeepAlive: -1, Control: control}
	return &http.Transport{
		// No environment proxy and no pooled sockets: every health sample
		// verifies the current route rather than a pre-transition connection.
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			return dialer.DialContext(ctx, "tcp4", address)
		},
		TLSClientConfig:        &tls.Config{MinVersion: tls.VersionTLS12, ServerName: serverName},
		TLSNextProto:           make(map[string]func(string, *tls.Conn) http.RoundTripper),
		DisableKeepAlives:      true,
		TLSHandshakeTimeout:    2 * time.Second,
		ResponseHeaderTimeout:  2 * time.Second,
		MaxResponseHeaderBytes: 16 << 10,
	}
}

func resolverClient(transport http.RoundTripper) *http.Client {
	return &http.Client{Transport: transport, Timeout: 3 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

// SetTunnelAddress forces the tunnel health check through the VPN outbound.
// A connection to the name's real address can leave as direct traffic in
// selective mode and report a dead server as healthy.
func (r *Resolver) SetTunnelAddress(allocate func(string) (netip.Addr, error)) {
	r.tunnelAddress = allocate
}

func (r *Resolver) Close() {
	for _, transport := range r.transports {
		transport.CloseIdleConnections()
	}
}

func (r *Resolver) ProbeTCP(ctx context.Context, address string) error {
	dialer := &net.Dialer{Timeout: 2 * time.Second, KeepAlive: -1, Control: r.control}
	conn, err := dialer.DialContext(ctx, "tcp4", address)
	if err != nil {
		return ErrHealth
	}
	return conn.Close()
}

func (r *Resolver) Resolve(ctx context.Context, query *dns.Msg, action fakedns.Action) (*dns.Msg, error) {
	if query == nil || len(query.Question) != 1 || query.Len() > maximumResolverBody {
		return nil, ErrResolver
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	switch action {
	case fakedns.Local:
		return r.local(ctx, query)
	case fakedns.Direct:
		return r.doh(ctx, query, r.direct)
	case fakedns.VPN:
		return r.doh(ctx, query, r.vpn)
	default:
		return nil, ErrResolver
	}
}

func validDNSReply(query, reply *dns.Msg) bool {
	if reply == nil || !reply.Response || reply.Id != query.Id || reply.Opcode != dns.OpcodeQuery || reply.Truncated || len(reply.Question) != 1 || reply.Len() > maximumResolverBody {
		return false
	}
	a, b := query.Question[0], reply.Question[0]
	return strings.EqualFold(a.Name, b.Name) && a.Qtype == b.Qtype && a.Qclass == b.Qclass
}

func boundTTLs(reply *dns.Msg) {
	for _, records := range [][]dns.RR{reply.Answer, reply.Ns, reply.Extra} {
		for _, record := range records {
			if record.Header().Rrtype != dns.TypeOPT && record.Header().Ttl > 300 {
				record.Header().Ttl = 300
			}
		}
	}
}

func (r *Resolver) doh(ctx context.Context, query *dns.Msg, client *http.Client) (*dns.Msg, error) {
	encoded, err := query.Pack()
	if err != nil || len(encoded) > maximumResolverBody {
		return nil, ErrResolver
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, r.dohURL, bytes.NewReader(encoded))
	if err != nil {
		return nil, ErrResolver
	}
	request.Header.Set("Content-Type", "application/dns-message")
	request.Header.Set("Accept", "application/dns-message")
	request.Header.Set("Cache-Control", "no-store, no-cache")
	request.Header.Set("Pragma", "no-cache")
	response, err := client.Do(request)
	if err != nil {
		return nil, ErrResolver
	}
	defer response.Body.Close()
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/dns-message" || response.StatusCode != http.StatusOK {
		return nil, ErrResolver
	}
	encoded, err = io.ReadAll(io.LimitReader(response.Body, maximumResolverBody+1))
	if err != nil || len(encoded) > maximumResolverBody {
		return nil, ErrResolver
	}
	reply := new(dns.Msg)
	if reply.Unpack(encoded) != nil || !validDNSReply(query, reply) {
		return nil, ErrResolver
	}
	boundTTLs(reply)
	return reply, nil
}

func (r *Resolver) local(ctx context.Context, query *dns.Msg) (*dns.Msg, error) {
	for _, server := range r.servers {
		host, _, err := net.SplitHostPort(server)
		ip, parseErr := netip.ParseAddr(host)
		if err != nil || parseErr != nil {
			return nil, ErrResolver
		}
		family := "4"
		if ip.Is6() {
			family = "6"
		}
		dialer := &net.Dialer{Timeout: time.Second, Control: r.control}
		client := &dns.Client{Net: "udp" + family, Dialer: dialer, Timeout: time.Second, UDPSize: maximumResolverBody}
		reply, _, err := client.ExchangeContext(ctx, query, server)
		if err == nil && reply.Truncated {
			client.Net = "tcp" + family
			reply, _, err = client.ExchangeContext(ctx, query, server)
		}
		if err == nil && validDNSReply(query, reply) {
			boundTTLs(reply)
			return reply, nil
		}
		if ctx.Err() != nil {
			break
		}
	}
	return nil, ErrResolver
}

// Bootstrap never consults the resolver that will point at our FakeDNS. The
// numeric DoH endpoint and physically bound socket remain valid after DNS swap.
func (r *Resolver) Bootstrap(ctx context.Context, host string) ([]string, error) {
	return r.bootstrap(ctx, host, r.direct)
}

// BootstrapThroughTunnel resolves through the VPN only after the physical DoH
// path has failed. Split-default routes make a bound socket to 1.1.1.1
// unreachable, while HTTPS to that address through the tunnel still returns
// the real A record rather than a FakeDNS address.
func (r *Resolver) BootstrapThroughTunnel(ctx context.Context, host string) ([]string, error) {
	return r.bootstrap(ctx, host, r.vpn)
}

func (r *Resolver) bootstrap(ctx context.Context, host string, client *http.Client) ([]string, error) {
	if ip, err := netip.ParseAddr(host); err == nil {
		if !ip.Is4() || ip.IsUnspecified() || ip.IsMulticast() || ip.IsLoopback() || fakedns.Pool.Contains(ip) {
			return nil, ErrResolver
		}
		return []string{ip.String()}, nil
	}
	if client == nil {
		return nil, ErrResolver
	}
	query := new(dns.Msg)
	query.SetQuestion(dns.Fqdn(host), dns.TypeA)
	if _, ok := dns.IsDomainName(query.Question[0].Name); !ok || len(host) > 253 {
		return nil, ErrResolver
	}
	reply, err := r.doh(ctx, query, client)
	if err != nil || reply.Rcode != dns.RcodeSuccess {
		return nil, ErrResolver
	}
	addresses := make([]string, 0, 4)
	seen := make(map[string]bool)
	for _, rr := range reply.Answer {
		record, ok := rr.(*dns.A)
		if !ok {
			continue
		}
		ip, ok := netip.AddrFromSlice(record.A)
		if !ok {
			return nil, ErrResolver
		}
		ip = ip.Unmap()
		if ip.IsUnspecified() || ip.IsMulticast() || ip.IsLoopback() || fakedns.Pool.Contains(ip) {
			return nil, ErrResolver
		}
		if !seen[ip.String()] {
			addresses = append(addresses, ip.String())
			seen[ip.String()] = true
		}
		if len(addresses) == 8 {
			break
		}
	}
	if len(addresses) == 0 {
		return nil, ErrResolver
	}
	return addresses, nil
}

func nonce() (string, error) {
	var random [12]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", ErrHealth
	}
	return hex.EncodeToString(random[:]), nil
}

// Probe uses actual system TUN routing when direct=false. A SOCKS listener or
// cached DNS response cannot by itself produce a successful TLS HTTP exchange.
func (r *Resolver) Probe(ctx context.Context, direct bool) error {
	ctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	if direct {
		random, err := nonce()
		if err != nil {
			return ErrHealth
		}
		query := new(dns.Msg)
		query.SetQuestion("probe-"+random+".matveevvpn.invalid.", dns.TypeA)
		reply, err := r.doh(ctx, query, r.direct)
		if err != nil || (reply.Rcode != dns.RcodeSuccess && reply.Rcode != dns.RcodeNameError) {
			return ErrHealth
		}
		return nil
	}
	result := make(chan error, len(r.healthURLs))
	for _, endpoint := range r.healthURLs {
		go func(endpoint string) { result <- r.probeHTTPS(ctx, endpoint) }(endpoint)
	}
	for range r.healthURLs {
		select {
		case err := <-result:
			if err == nil {
				return nil
			}
		case <-ctx.Done():
			return ErrHealth
		}
	}
	return ErrHealth
}

func (r *Resolver) probeHTTPS(ctx context.Context, endpoint string) error {
	random, err := nonce()
	if err != nil {
		return ErrHealth
	}
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Scheme != "https" {
		return ErrHealth
	}
	values := parsed.Query()
	values.Set("matveevvpn_nonce", random)
	parsed.RawQuery = values.Encode()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return ErrHealth
	}
	request.Header.Set("Cache-Control", "no-cache, no-store")
	request.Header.Set("Pragma", "no-cache")
	client := r.health
	if r.tunnelAddress != nil {
		tunneled, err := r.tunnelClient(parsed)
		if err != nil {
			return ErrHealth
		}
		client = tunneled
	}
	response, err := client.Do(request)
	if err != nil {
		return ErrHealth
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return ErrHealth
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maximumResolverBody+1))
	if err != nil || len(body) == 0 || len(body) > maximumResolverBody {
		return ErrHealth
	}
	return nil
}

func (r *Resolver) tunnelClient(parsed *url.URL) (*http.Client, error) {
	host := parsed.Hostname()
	address, err := r.tunnelAddress(host)
	if err != nil || !fakedns.Pool.Contains(address) {
		return nil, ErrHealth
	}
	port := parsed.Port()
	if port == "" {
		port = "443"
	}
	base, ok := r.health.Transport.(*http.Transport)
	if !ok {
		return nil, ErrHealth
	}
	transport := base.Clone()
	target := net.JoinHostPort(address.String(), port)
	dialer := &net.Dialer{Timeout: 2 * time.Second, KeepAlive: -1}
	transport.DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
		return dialer.DialContext(ctx, "tcp4", target)
	}
	if transport.TLSClientConfig != nil && transport.TLSClientConfig.ServerName == "" {
		transport.TLSClientConfig = transport.TLSClientConfig.Clone()
		transport.TLSClientConfig.ServerName = host
	}
	return resolverClient(transport), nil
}
