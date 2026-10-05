package lists

import (
	"strings"
	"testing"

	"matveevvpn/runtime/internal/policy"
)

func TestImportRejectsUnknownOperators(t *testing.T) {
	for _, raw := range []string{
		`{"version":2,"rules":[{"process_name":"Safari"}]}`,
		`{"version":2,"rules":[{"domain_suffix":["example.com"],"network":"tcp"}]}`,
		`{"version":1,"rules":[]}`,
		`{"version":2,"rules":[{"domain":""}]}`,
		`{"version":2,"extra":true,"rules":[]}`,
	} {
		if _, _, err := ImportSing([]byte(raw), policy.VPN); err == nil {
			t.Fatalf("accepted unsupported source: %s", raw)
		}
	}
}

func TestPinnedCatalogsMatchAdmittedRules(t *testing.T) {
	for name := range presetFiles {
		domains, ips, err := Preset(name, policy.VPN)
		if err != nil || len(domains)+len(ips) == 0 {
			t.Fatalf("preset %s: %d domains %d ips %v", name, len(domains), len(ips), err)
		}
		snapshot := policy.Snapshot{Mode: "selective", Domains: domains, IPs: ips}
		compiled, err := policy.Compile(snapshot)
		if err != nil {
			t.Fatalf("preset %s did not compile: %v", name, err)
		}
		if name == "youtube" && compiled.Decision("ytimg.com") != policy.VPN {
			t.Fatal("youtube preset lost a known suffix")
		}
		if name == "telegram" {
			found := false
			for _, rule := range ips {
				if rule.Prefix == "149.154.160.0/20" && rule.Route == policy.VPN {
					found = true
				}
			}
			if !found {
				t.Fatal("telegram IP set lost 149.154.160.0/20")
			}
		}
	}
	if _, _, err := Preset("not-a-preset", policy.VPN); err == nil {
		t.Fatal("unknown preset was admitted")
	}
}

func TestHaGeZiAndUserRulesShareTheCompiler(t *testing.T) {
	raw := []byte("# comment\n\nads.example\ntracker.example\n")
	blocked, err := ImportHaGeZi(raw)
	if err != nil || len(blocked) != 2 {
		t.Fatal(err)
	}
	if _, err = ImportHaGeZi([]byte("ads.example\nbad_domain.example\n")); err == nil {
		t.Fatal("one bad advertising domain was ignored")
	}
	compiled, err := Compile(Intent{
		Mode: "selective", Presets: []string{"youtube"}, UserDomains: []string{"*.chosen.example"}, BlockDomains: blocked,
	})
	if err != nil {
		t.Fatal(err)
	}
	if compiled.Decision("ytimg.com") != policy.VPN || compiled.Decision("sub.chosen.example") != policy.VPN {
		t.Fatal("preset or user domain was dropped")
	}
	if compiled.Decision("ads.example") != policy.Block || compiled.Decision("unknown.example") != policy.Direct {
		t.Fatal("block priority or selective final changed")
	}
	compiled.Snapshot.Mode = "all"
	full, err := policy.Compile(compiled.Snapshot)
	if err != nil || full.Decision("unknown.example") != policy.VPN || full.Decision("ads.example") != policy.Block {
		t.Fatal("full mode changed block priority")
	}
	if strings.Contains(errString(Compile(Intent{Mode: "selective", Presets: []string{"private-token"}})), "private-token") {
		t.Fatal("rejected preset echoed its name")
	}
}

func errString(policy *policy.Policy, err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
