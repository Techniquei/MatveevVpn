// Package lists turns pinned public rule sources into admitted policy rules.
// Unknown source operators reject the whole document.
package lists

import (
	"bufio"
	"bytes"
	"embed"
	"encoding/json"
	"io"
	"strings"

	"matveevvpn/runtime/internal/policy"
)

//go:embed catalog/*.json
var catalogs embed.FS

var ErrRejected = policy.ErrInvalid

var ruleKeys = map[string]string{
	"domain":        "exact",
	"domain_suffix": "suffix",
	"domain_keyword": "keyword",
	"domain_regex":  "regex",
}

type document struct {
	Version int                        `json:"version"`
	Rules   []map[string]json.RawMessage `json:"rules"`
}

// ImportSing converts one sing-box rule-set JSON document.
// Domain rules use route for every domain condition. IP conditions use the same route.
func ImportSing(data []byte, route policy.Route) (domains []policy.DomainRule, ips []policy.IPRule, err error) {
	if route != policy.VPN && route != policy.Direct && route != policy.Block {
		return nil, nil, ErrRejected
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var doc document
	if decoder.Decode(&doc) != nil || doc.Version != 2 {
		return nil, nil, ErrRejected
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return nil, nil, ErrRejected
	}
	for _, rule := range doc.Rules {
		for key, raw := range rule {
			kind, domain := ruleKeys[key]
			if key == "ip_cidr" {
				values, err := stringValues(raw)
				if err != nil {
					return nil, nil, ErrRejected
				}
				for _, value := range values {
					ips = append(ips, policy.IPRule{Prefix: value, Route: route})
				}
				continue
			}
			if !domain {
				return nil, nil, ErrRejected
			}
			values, err := stringValues(raw)
			if err != nil {
				return nil, nil, ErrRejected
			}
			for _, value := range values {
				domains = append(domains, policy.DomainRule{Kind: kind, Value: strings.ToLower(value), Route: route})
			}
		}
	}
	return domains, ips, nil
}

func stringValues(raw json.RawMessage) ([]string, error) {
	var one string
	if json.Unmarshal(raw, &one) == nil {
		if one == "" {
			return nil, ErrRejected
		}
		return []string{one}, nil
	}
	var many []string
	if json.Unmarshal(raw, &many) != nil || len(many) == 0 {
		return nil, ErrRejected
	}
	for _, value := range many {
		if value == "" {
			return nil, ErrRejected
		}
	}
	return many, nil
}

// ImportHaGeZi reads a domain-only block list. Comments and blank lines are ignored.
// One invalid domain rejects the whole list.
func ImportHaGeZi(data []byte) ([]string, error) {
	var domains []string
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	for scanner.Scan() {
		line := strings.ToLower(strings.TrimSpace(scanner.Text()))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if !policy.Domain(line) || !strings.Contains(line, ".") {
			return nil, ErrRejected
		}
		domains = append(domains, line)
	}
	if scanner.Err() != nil || len(domains) == 0 {
		return nil, ErrRejected
	}
	return domains, nil
}

// Catalog is the pinned MetaCubeX sing snapshot shipped with the runtime.
func Catalog(route policy.Route) (domains []policy.DomainRule, ips []policy.IPRule, err error) {
	entries, err := catalogs.ReadDir("catalog")
	if err != nil {
		return nil, nil, ErrRejected
	}
	for _, entry := range entries {
		data, err := catalogs.ReadFile("catalog/" + entry.Name())
		if err != nil {
			return nil, nil, ErrRejected
		}
		nextDomains, nextIPs, err := ImportSing(data, route)
		if err != nil {
			return nil, nil, err
		}
		domains = append(domains, nextDomains...)
		ips = append(ips, nextIPs...)
	}
	return domains, ips, nil
}

var presetFiles = map[string][2]string{
	"youtube":        {"geosite-youtube.json", ""},
	"telegram":       {"geosite-telegram.json", "geoip-telegram.json"},
	"whatsapp":       {"geosite-whatsapp.json", ""},
	"instagram":      {"geosite-instagram.json", ""},
	"facebook":       {"geosite-facebook.json", "geoip-facebook.json"},
	"twitter":        {"geosite-twitter.json", "geoip-twitter.json"},
	"discord":        {"geosite-discord.json", ""},
	"openai":         {"geosite-openai.json", ""},
	"anthropic":      {"geosite-anthropic.json", ""},
	"google-gemini":  {"geosite-google-gemini.json", ""},
	"cursor":         {"geosite-cursor.json", ""},
	"github-copilot": {"geosite-github-copilot.json", ""},
	"spotify":        {"geosite-spotify.json", ""},
}

// Preset loads one category. An unknown name rejects the request.
func Preset(name string, route policy.Route) (domains []policy.DomainRule, ips []policy.IPRule, err error) {
	files, ok := presetFiles[name]
	if !ok {
		return nil, nil, ErrRejected
	}
	for _, file := range files {
		if file == "" {
			continue
		}
		data, err := catalogs.ReadFile("catalog/" + file)
		if err != nil {
			return nil, nil, ErrRejected
		}
		nextDomains, nextIPs, err := ImportSing(data, route)
		if err != nil {
			return nil, nil, err
		}
		domains = append(domains, nextDomains...)
		ips = append(ips, nextIPs...)
	}
	return domains, ips, nil
}
