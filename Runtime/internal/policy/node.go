package policy

import (
	"encoding/json"
	"math"
	"net/netip"
	"net/url"
	"strings"

	"github.com/xtls/libxray/share"
)

// ParseNode admits one libXray share link and returns the server host plus a
// VPN outbound. XHTTP extras may tune the transport but cannot select files,
// environment, listeners or nested dialers. Legacy VMess JSON, Clash and raw
// Xray documents are not links.
func ParseNode(n Node) (string, map[string]any, error) {
	uri := strings.TrimSpace(n.URI)
	if len(uri) == 0 || len(uri) > 65536 || strings.ContainsAny(uri, "\r\n\x00") || !shareScheme(uri) || rejectedQuery(uri) {
		return "", nil, ErrInvalid
	}
	if parsed, err := url.Parse(uri); err == nil && (strings.EqualFold(parsed.Scheme, "vless") || strings.EqualFold(parsed.Scheme, "vmess")) {
		if _, set := parsed.User.Password(); set {
			return "", nil, ErrInvalid
		}
	}
	encoded, err := share.ConvertShareLinksToXrayJson(uri, "")
	if err != nil {
		return "", nil, ErrInvalid
	}
	var document struct {
		Outbounds []map[string]any `json:"outbounds"`
	}
	if json.Unmarshal(encoded, &document) != nil || len(document.Outbounds) != 1 {
		return "", nil, ErrInvalid
	}
	outbound := document.Outbounds[0]
	host, err := admitOutbound(outbound)
	if err != nil {
		return "", nil, err
	}
	if parsed, err := url.Parse(uri); err == nil && parsed.Hostname() != "" && !sameHost(parsed.Hostname(), host) {
		return "", nil, ErrInvalid
	}
	outbound["tag"] = "vpn"
	return host, outbound, nil
}

func shareScheme(uri string) bool {
	scheme, _, ok := strings.Cut(uri, "://")
	if !ok || scheme == "" || strings.ContainsAny(scheme, " \t#") {
		return false
	}
	switch strings.ToLower(scheme) {
	case "vless", "vmess", "trojan", "ss", "socks", "hysteria2", "hy2":
		return true
	default:
		return false
	}
}

func rejectedQuery(uri string) bool {
	_, query, ok := strings.Cut(uri, "?")
	if !ok {
		return false
	}
	query, _, _ = strings.Cut(query, "#")
	values, err := url.ParseQuery(query)
	if err != nil {
		return true
	}
	for key, items := range values {
		if len(items) != 1 || strings.ContainsAny(items[0], "\r\n\x00") || forbiddenKey(key) {
			return true
		}
	}
	return false
}

func admitOutbound(outbound map[string]any) (string, error) {
	for key := range outbound {
		switch key {
		case "protocol", "settings", "streamSettings", "tag":
		default:
			return "", ErrInvalid
		}
	}
	protocol, _ := outbound["protocol"].(string)
	settings, _ := outbound["settings"].(map[string]any)
	allowedSettings, known := protocolSettings[protocol]
	if !known || settings == nil {
		return "", ErrInvalid
	}
	for key := range settings {
		if !allowedSettings[key] {
			return "", ErrInvalid
		}
	}
	address, _ := settings["address"].(string)
	host, err := admitHost(address)
	if err != nil {
		return "", err
	}
	if _, ok := portNumber(settings["port"]); !ok {
		return "", ErrInvalid
	}
	if stream, ok := outbound["streamSettings"].(map[string]any); ok {
		if err = admitStream(stream); err != nil {
			return "", err
		}
	}
	if forbiddenValue(outbound) {
		return "", ErrInvalid
	}
	return host, nil
}

var protocolSettings = map[string]map[string]bool{
	"vless":       {"address": true, "port": true, "id": true, "flow": true, "encryption": true},
	"vmess":       {"address": true, "port": true, "id": true, "security": true},
	"trojan":      {"address": true, "port": true, "password": true},
	"shadowsocks": {"address": true, "port": true, "method": true, "password": true},
	"socks":       {"address": true, "port": true, "user": true, "pass": true},
	"hysteria":    {"version": true, "address": true, "port": true},
}

func admitStream(stream map[string]any) error {
	for key := range stream {
		switch key {
		case "network", "security", "rawSettings", "kcpSettings", "wsSettings", "grpcSettings", "httpupgradeSettings", "xhttpSettings", "hysteriaSettings", "tlsSettings", "realitySettings", "finalmask":
		default:
			return ErrInvalid
		}
	}
	if network, ok := stream["network"].(string); ok {
		switch network {
		case "raw", "kcp", "ws", "grpc", "httpupgrade", "xhttp", "hysteria":
		default:
			return ErrInvalid
		}
	}
	if security, ok := stream["security"].(string); ok && security != "" && security != "none" && security != "tls" && security != "reality" {
		return ErrInvalid
	}
	if xhttp, ok := stream["xhttpSettings"].(map[string]any); ok {
		if extra, exists := xhttp["extra"]; exists && !admitExtra(extra) {
			return ErrInvalid
		}
	}
	return nil
}

func admitExtra(value any) bool {
	extra, ok := value.(map[string]any)
	if !ok || extra == nil {
		return false
	}
	for key, child := range extra {
		switch key {
		case "headers", "xPaddingBytes", "xPaddingObfsMode", "xPaddingKey", "xPaddingHeader", "xPaddingPlacement", "uplinkHTTPMethod", "sessionIDPlacement", "sessionIDKey", "sessionIDTable", "sessionIDLength", "seqPlacement", "seqKey", "uplinkDataPlacement", "noGRPCHeader", "noSSEHeader", "scMaxEachPostBytes", "scMinPostsIntervalMs", "scMaxBufferedPosts", "scStreamUpServerSecs", "serverMaxHeaderBytes":
		case "xmux":
			fields, ok := child.(map[string]any)
			if !ok || fields == nil {
				return false
			}
			for name := range fields {
				switch name {
				case "maxConcurrency", "maxConnections", "cMaxReuseTimes", "hMaxRequestTimes", "hMaxReusableSecs", "hKeepAlivePeriod":
				default:
					return false
				}
			}
		default:
			return false
		}
	}
	return true
}

func admitHost(address string) (string, error) {
	host := strings.Trim(strings.ToLower(strings.TrimSpace(address)), "[]")
	if host == "" || strings.HasPrefix(host, "env:") {
		return "", ErrInvalid
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		if ip.Zone() != "" {
			return "", ErrInvalid
		}
		return ip.String(), nil
	}
	if !Domain(host) {
		return "", ErrInvalid
	}
	return host, nil
}

func portNumber(value any) (int, bool) {
	number, ok := value.(float64)
	if !ok || number != math.Trunc(number) || number < 1 || number > 65535 {
		return 0, false
	}
	return int(number), true
}

func sameHost(left, right string) bool {
	normalize := func(value string) string {
		return strings.Trim(strings.ToLower(strings.TrimSpace(value)), "[]")
	}
	return normalize(left) == normalize(right)
}

func forbiddenKey(key string) bool {
	switch strings.ToLower(key) {
	case "env", "config", "sendthrough", "downloadsettings", "dialerproxy", "proxysettings", "sockopt":
		return true
	default:
		return false
	}
}

func forbiddenValue(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if forbiddenKey(key) || forbiddenValue(child) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if forbiddenValue(child) {
				return true
			}
		}
	}
	return false
}
