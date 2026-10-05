package policy

import (
	"encoding/json"
	"net"
	"net/netip"
	"strconv"
	"strings"

	"github.com/xtls/xray-core/common/geodata"
	"google.golang.org/protobuf/proto"
)

type ConfigOptions struct {
	Interface  string
	TUN        string
	ServerIP   string
	LAN        []string
	DNSAddress string
}
type Artifacts struct {
	Config  []byte
	Domains []byte
	IPs     []byte
}

// Geodata and DNS selection are compiled from the same admitted rule sequence.
// Compact assets keep large HaGeZi lists out of the bounded worker envelope.
func (p *Policy) Build(o ConfigOptions) (Artifacts, error) {
	if !InterfaceName.MatchString(o.Interface) || !strings.HasPrefix(o.TUN, "utun") || !InterfaceName.MatchString(o.TUN) {
		return Artifacts{}, ErrInvalid
	}
	dnsHost, dnsPort, err := loopbackDNS(o.DNSAddress)
	if err != nil {
		return Artifacts{}, err
	}
	server, err := netip.ParseAddr(o.ServerIP)
	if err != nil || !server.Is4() {
		return Artifacts{}, ErrInvalid
	}
	_, vpn, err := ParseNode(p.SelectedNode())
	if err != nil {
		return Artifacts{}, err
	}
	stream, _ := vpn["streamSettings"].(map[string]any)
	if stream == nil {
		stream = map[string]any{}
		vpn["streamSettings"] = stream
	}
	stream["sockopt"] = map[string]any{"interface": o.Interface, "domainStrategy": "UseIPv4"}
	settings, ok := vpn["settings"].(map[string]any)
	if !ok {
		return Artifacts{}, ErrInvalid
	}
	settings["address"] = server.String()
	groups := []*geodata.GeoSite{}
	rules := []any{}
	add := func(values map[string]any) { values["type"] = "field"; rules = append(rules, values) }
	// FakeDNS metadata changes synthetic targets to names before any route rule.
	add(map[string]any{"ip": []string{"198.18.0.0/15"}, "outboundTag": "block"})
	add(map[string]any{"inboundTag": []string{"tun"}, "port": "53", "outboundTag": "dns"})
	lan := []string{"127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10"}
	for _, cidr := range o.LAN {
		if _, e := netip.ParsePrefix(cidr); e != nil {
			return Artifacts{}, ErrInvalid
		}
		lan = append(lan, cidr)
	}
	add(map[string]any{"ip": append(lan, server.String()+"/32"), "outboundTag": "direct"})
	add(map[string]any{"ip": []string{"::/0"}, "outboundTag": "block"})
	add(map[string]any{"domain": []string{"full:api4.ipify.org", "full:www.cloudflare.com"}, "outboundTag": "vpn"})
	add(map[string]any{"inboundTag": []string{"dns-vpn"}, "outboundTag": "vpn"})
	add(map[string]any{"inboundTag": []string{"dns-direct"}, "outboundTag": "direct"})
	add(map[string]any{"ip": []string{"1.1.1.1/32"}, "outboundTag": "vpn"})
	codeIndex := 0
	dnsServers := []any{}
	appendGroup := func(tag Route, domains []*geodata.Domain) {
		if len(domains) == 0 {
			return
		}
		codeIndex++
		code := "R" + itoa(codeIndex)
		groups = append(groups, &geodata.GeoSite{Code: code, Domain: domains})
		reference := "ext:policy-domains.dat:" + strings.ToLower(code)
		add(map[string]any{"domain": []string{reference}, "outboundTag": string(tag)})
		if tag != Block {
			dnsServers = append(dnsServers, map[string]any{"address": "https://1.1.1.1/dns-query", "domains": []string{reference}, "tag": "dns-" + string(tag), "skipFallback": true, "finalQuery": true, "queryStrategy": "UseIPv4", "timeoutMs": 2000})
		}
	}
	blocked := []*geodata.Domain{}
	for _, d := range p.Snapshot.BlockDomains {
		blocked = append(blocked, &geodata.Domain{Type: geodata.Domain_Domain, Value: d})
	}
	for _, r := range p.Snapshot.Domains {
		if r.Route == Block {
			blocked = append(blocked, geoDomain(r))
		}
	}
	appendGroup(Block, blocked)
	var previous Route
	group := []*geodata.Domain{}
	for _, r := range p.Snapshot.Domains {
		if r.Route == Block {
			continue
		}
		if previous != "" && previous != r.Route {
			appendGroup(previous, group)
			group = nil
		}
		previous = r.Route
		group = append(group, geoDomain(r))
	}
	appendGroup(previous, group)
	geoIPs := []*geodata.GeoIP{}
	ipindex := 0
	// Preserve sequence for overlapping IP presets just as for domain rules.
	for _, r := range p.Snapshot.IPs {
		prefix, _ := netip.ParsePrefix(r.Prefix)
		ipindex++
		code := "I" + itoa(ipindex)
		geoIPs = append(geoIPs, &geodata.GeoIP{Code: code, Cidr: []*geodata.CIDR{{Ip: prefix.Addr().AsSlice(), Prefix: uint32(prefix.Bits())}}})
		add(map[string]any{"ip": []string{"ext:policy-ips.dat:" + strings.ToLower(code)}, "outboundTag": string(r.Route)})
	}
	final := Direct
	if p.Snapshot.Mode == "all" {
		final = VPN
	}
	dnsServers = append(dnsServers, map[string]any{"address": "https://1.1.1.1/dns-query", "tag": "dns-" + string(final), "queryStrategy": "UseIPv4", "timeoutMs": 2000})
	direct := map[string]any{"tag": "direct", "protocol": "freedom", "settings": map[string]any{}, "streamSettings": map[string]any{"sockopt": map[string]any{"interface": o.Interface, "domainStrategy": "UseIPv4"}}}
	outbounds := []any{direct, vpn}
	if final == VPN {
		outbounds = []any{vpn, direct}
	}
	outbounds = append(outbounds, map[string]any{"tag": "block", "protocol": "blackhole"}, map[string]any{"tag": "dns", "protocol": "dns", "settings": map[string]any{"address": dnsHost, "port": dnsPort, "network": "udp"}, "streamSettings": map[string]any{"sockopt": map[string]any{"interface": "lo0"}}})
	config := map[string]any{
		"log":       map[string]string{"loglevel": "none"},
		"inbounds":  []any{map[string]any{"tag": "tun", "protocol": "tun", "settings": map[string]any{"name": o.TUN, "mtu": 1500, "gateway": []string{"169.254.250.1/30"}}, "sniffing": map[string]any{"enabled": true, "metadataOnly": true, "destOverride": []string{"fakedns"}}}},
		"outbounds": outbounds,
		"dns":       map[string]any{"servers": dnsServers, "queryStrategy": "UseIPv4", "disableFallbackIfMatch": true},
		"routing":   map[string]any{"domainStrategy": "IPIfNonMatch", "rules": rules},
	}
	data, err := json.Marshal(config)
	if err != nil || len(data) > 1<<20 {
		return Artifacts{}, ErrInvalid
	}
	domains, err := proto.Marshal(&geodata.GeoSiteList{Entry: groups})
	if err != nil {
		return Artifacts{}, ErrInvalid
	}
	ips, err := proto.Marshal(&geodata.GeoIPList{Entry: geoIPs})
	if err != nil {
		return Artifacts{}, ErrInvalid
	}
	return Artifacts{Config: data, Domains: domains, IPs: ips}, nil
}
func loopbackDNS(address string) (string, int, error) {
	if address == "" {
		return "127.0.0.1", 53, nil
	}
	host, portText, err := net.SplitHostPort(address)
	port, portErr := strconv.Atoi(portText)
	ip, parseErr := netip.ParseAddr(host)
	if err != nil || portErr != nil || parseErr != nil || !ip.IsLoopback() || port < 1 || port > 65535 {
		return "", 0, ErrInvalid
	}
	return ip.String(), port, nil
}

func geoDomain(r DomainRule) *geodata.Domain {
	types := map[string]geodata.Domain_Type{"exact": geodata.Domain_Full, "suffix": geodata.Domain_Domain, "keyword": geodata.Domain_Substr, "regex": geodata.Domain_Regex}
	return &geodata.Domain{Type: types[r.Kind], Value: r.Value}
}
func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for value > 0 {
		i--
		b[i] = byte(value%10) + '0'
		value /= 10
	}
	return string(b[i:])
}
