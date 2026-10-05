package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/netip"
	"path/filepath"
	"strings"
	"sync"

	"matveevvpn/runtime/internal/fakedns"

	corelog "github.com/xtls/xray-core/common/log"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/dns"
	_ "github.com/xtls/xray-core/main/distro/all"
)

var runtimeCore coreWorker

// An instance cannot be restarted after Close. Each activation and disposable
// validation owns a new instance; no libXray process-global instance is involved.
type coreWorker struct {
	mu       sync.Mutex
	instance *core.Instance
}

func (w *coreWorker) running() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.instance != nil && w.instance.IsRunning()
}

func (w *coreWorker) construct(encoded []byte, fakeDNSDirectory string, start bool) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.instance != nil {
		return errors.New("already_running")
	}
	instance, err := buildCoreInstance(encoded, fakeDNSDirectory)
	if err != nil {
		return err
	}
	if !start {
		return instance.Close()
	}
	if err := instance.Start(); err != nil {
		_ = instance.Close()
		return err
	}
	w.instance = instance
	return nil
}

func (w *coreWorker) stop() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.instance == nil {
		return nil
	}
	instance := w.instance
	w.instance = nil
	return instance.Close()
}

func buildCoreInstance(encoded []byte, fakeDNSDirectory string) (*core.Instance, error) {
	if fakeDNSDirectory != "" {
		if !filepath.IsAbs(fakeDNSDirectory) || hasBuiltinFakeDNS(encoded) {
			return nil, errors.New("invalid_fake_dns_configuration")
		}
	}
	// Parsing can emit deprecation warnings before the config's disabled logger
	// exists. Suppress that process-global default console handler as well.
	corelog.RegisterHandler(discardCoreLog{})
	config, err := core.LoadConfig("json", bytes.NewReader(encoded))
	if err != nil {
		return nil, err
	}
	instance, err := core.New(config)
	if err != nil {
		return nil, err
	}
	if fakeDNSDirectory != "" {
		// Dispatcher resolves this optional feature before Start. Adding it to a
		// running instance would neither register it nor resolve the callback.
		if err := instance.AddFeature(&persistentReverseHolder{directory: fakeDNSDirectory}); err != nil {
			_ = instance.Close()
			return nil, err
		}
	}
	return instance, nil
}

type discardCoreLog struct{}

func (discardCoreLog) Handle(corelog.Message) {}

// The service's durable table is the only allocator. A second builtin FakeDNS
// could otherwise generate different mappings inside this child process.
func hasBuiltinFakeDNS(encoded []byte) bool {
	var config map[string]json.RawMessage
	if json.Unmarshal(encoded, &config) != nil {
		return true
	}
	for key, value := range config {
		if strings.EqualFold(key, "fakeDns") && string(value) != "null" {
			return true
		}
		if strings.EqualFold(key, "dns") {
			var dnsConfig struct {
				Servers []json.RawMessage `json:"servers"`
			}
			if json.Unmarshal(value, &dnsConfig) != nil {
				return true
			}
			for _, server := range dnsConfig.Servers {
				var address string
				if json.Unmarshal(server, &address) != nil {
					var object struct {
						Address string `json:"address"`
					}
					if json.Unmarshal(server, &object) != nil {
						return true
					}
					address = object.Address
				}
				if strings.EqualFold(address, "fakedns") {
					return true
				}
			}
		}
	}
	return false
}

type persistentReverseHolder struct {
	directory string
}

var _ dns.FakeDNSEngineRev0 = (*persistentReverseHolder)(nil)

func (*persistentReverseHolder) Type() interface{} { return (*dns.FakeDNSEngine)(nil) }
func (*persistentReverseHolder) Start() error      { return nil }
func (*persistentReverseHolder) Close() error      { return nil }
func (*persistentReverseHolder) GetFakeIPForDomain(string) []xnet.Address {
	return nil
}
func (*persistentReverseHolder) GetFakeIPForDomain3(string, bool, bool) []xnet.Address {
	return nil
}

func (h *persistentReverseHolder) GetDomainFromFakeDNS(address xnet.Address) string {
	ip, ok := fakeDNSAddress(address)
	if !ok {
		return ""
	}
	// No negative cache: records published after the worker started must be
	// immediately visible before the service returns the new DNS answer.
	domain, err := fakedns.LookupRecord(h.directory, ip)
	if err != nil {
		return ""
	}
	return domain
}

func (*persistentReverseHolder) IsIPInIPPool(address xnet.Address) bool {
	_, ok := fakeDNSAddress(address)
	return ok
}

func fakeDNSAddress(address xnet.Address) (netip.Addr, bool) {
	if address == nil || !address.Family().IsIP() {
		return netip.Addr{}, false
	}
	ip, ok := netip.AddrFromSlice(address.IP())
	if !ok {
		return netip.Addr{}, false
	}
	ip = ip.Unmap()
	return ip, fakedns.Pool.Contains(ip)
}
