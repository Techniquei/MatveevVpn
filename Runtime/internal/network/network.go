// Package network owns only the DNS override and routes recorded in its private
// emergency journal. Creating the utun and admitting configuration belong to
// the supervisor and its worker.
package network

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	networksetup = "/usr/sbin/networksetup"
	scutil       = "/usr/sbin/scutil"
	routeTool    = "/sbin/route"
	netstat      = "/usr/sbin/netstat"
	ifconfigTool = "/sbin/ifconfig"
	fakePool     = "198.18.0.0/15"
	resolver     = "127.0.0.1"
	maxOutput    = 256 << 10
	maxJournal   = 128 << 10
)

var (
	ErrDiscover = errors.New("physical_network_unavailable")
	ErrConflict = errors.New("network_route_conflict")
	ErrChanged  = errors.New("network_state_changed")
	ErrJournal  = errors.New("network_journal_invalid")
	ErrCommand  = errors.New("network_command_failed")
	ErrInvalid  = errors.New("network_input_invalid")
)

// Runner is the one external command boundary. Tests must inject a fake.
// Executables and argument structure are selected by this package, never IPC.
type Runner interface {
	Run(context.Context, string, ...string) ([]byte, error)
}

type RunnerFunc func(context.Context, string, ...string) ([]byte, error)

func (f RunnerFunc) Run(ctx context.Context, executable string, args ...string) ([]byte, error) {
	return f(ctx, executable, args...)
}

type ExecRunner struct{}

type boundedOutput struct{ bytes.Buffer }

func (b *boundedOutput) Write(p []byte) (int, error) {
	if b.Len()+len(p) > maxOutput {
		return 0, ErrCommand
	}
	return b.Buffer.Write(p)
}

func (ExecRunner) Run(ctx context.Context, executable string, args ...string) ([]byte, error) {
	switch executable {
	case networksetup, scutil, routeTool, netstat, ifconfigTool, "/usr/bin/dscacheutil", "/usr/bin/killall":
	default:
		return nil, ErrCommand
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, args...)
	command.Env = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"}
	command.WaitDelay = 250 * time.Millisecond
	var output boundedOutput
	command.Stdout, command.Stderr = &output, &output
	if err := command.Run(); err != nil {
		// Tool output can disclose network details. Expose a fixed error instead.
		return nil, ErrCommand
	}
	return output.Bytes(), nil
}

type Physical struct {
	Interface   string   `json:"interface"`
	GatewayIPv4 string   `json:"gatewayIPv4"`
	GatewayIPv6 string   `json:"gatewayIPv6,omitempty"`
	Service     string   `json:"service"`
	DNS         []string `json:"dns"`
	LANCIDRs    []string `json:"lanCIDRs"`
}

type route struct {
	Prefix    string `json:"prefix"`
	Gateway   string `json:"gateway,omitempty"`
	Interface string `json:"interface"`
	ViaLink   bool   `json:"viaLink,omitempty"`
	Scoped    bool   `json:"scoped,omitempty"`
}

type mutation struct {
	Kind      string   `json:"kind"`
	Route     route    `json:"route,omitempty"`
	Service   string   `json:"service,omitempty"`
	Interface string   `json:"interface,omitempty"`
	BeforeDNS []string `json:"beforeDNS,omitempty"`
}

type journal struct {
	Version   int        `json:"version"`
	Physical  Physical   `json:"physical"`
	Tun       string     `json:"tun"`
	ServerIPs []string   `json:"serverIPs"`
	Changes   []mutation `json:"changes"`
}

type Adapter struct {
	mu        sync.Mutex
	directory string
	runner    Runner
	journal   *journal
}

var interfaceName = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9]{0,31}$`)
var tunnelName = regexp.MustCompile(`^utun[0-9]{1,6}$`)

func validPhysical(p Physical) bool {
	if !interfaceName.MatchString(p.Interface) || strings.HasPrefix(p.Interface, "utun") || p.Interface == "lo0" ||
		p.Service == "" || len(p.Service) > 256 || strings.ContainsAny(p.Service, "\x00\r\n") || strings.HasPrefix(p.Service, "-") {
		return false
	}
	gateway, err := netip.ParseAddr(p.GatewayIPv4)
	if err != nil || !gateway.Is4() {
		return false
	}
	if p.GatewayIPv6 != "" {
		gateway, err := netip.ParseAddr(p.GatewayIPv6)
		if err != nil || !gateway.Is6() || gateway.Zone() != "" && gateway.Zone() != p.Interface {
			return false
		}
	}
	for _, value := range p.DNS {
		if _, err := netip.ParseAddr(value); err != nil {
			return false
		}
	}
	for _, value := range p.LANCIDRs {
		if _, err := netip.ParsePrefix(value); err != nil {
			return false
		}
	}
	return true
}

// Open reads private recovery state without executing a command or changing
// networking. The supervisor must call Restore before its startup reconcile.
func Open(directory string, runner Runner) (*Adapter, error) {
	if runner == nil {
		runner = ExecRunner{}
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, ErrJournal
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return nil, ErrJournal
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || int(stat.Uid) != os.Geteuid() {
		return nil, ErrJournal
	}
	a := &Adapter{directory: directory, runner: runner}
	path := filepath.Join(directory, "network-journal.json")
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if errors.Is(err, os.ErrNotExist) {
		return a, nil
	}
	if err != nil {
		return nil, ErrJournal
	}
	defer file.Close()
	info, err = file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > maxJournal {
		return nil, ErrJournal
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || int(stat.Uid) != os.Geteuid() {
		return nil, ErrJournal
	}
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	var saved journal
	var trailing any
	if decoder.Decode(&saved) != nil || decoder.Decode(&trailing) != io.EOF || saved.Version != 1 ||
		!validPhysical(saved.Physical) || !tunnelName.MatchString(saved.Tun) || len(saved.Changes) > 64 || len(saved.ServerIPs) > 32 {
		return nil, ErrJournal
	}
	for _, ip := range saved.ServerIPs {
		if address, err := netip.ParseAddr(ip); err != nil || address.Zone() != "" {
			return nil, ErrJournal
		}
	}
	for _, change := range saved.Changes {
		switch change.Kind {
		case "dns":
			if change.Service != saved.Physical.Service || change.Interface != saved.Physical.Interface || len(change.BeforeDNS) > 16 {
				return nil, ErrJournal
			}
			for _, value := range change.BeforeDNS {
				if _, err := netip.ParseAddr(value); err != nil {
					return nil, ErrJournal
				}
			}
		case "route":
			if !validRoute(change.Route) {
				return nil, ErrJournal
			}
		default:
			return nil, ErrJournal
		}
	}
	a.journal = &saved
	return a, nil
}

func validRoute(r route) bool {
	prefix, err := netip.ParsePrefix(r.Prefix)
	if err != nil || prefix != prefix.Masked() || !interfaceName.MatchString(r.Interface) {
		return false
	}
	if r.ViaLink {
		return r.Gateway == ""
	}
	gateway, err := netip.ParseAddr(r.Gateway)
	return err == nil && gateway.Is4() == prefix.Addr().Is4() && (gateway.Zone() == "" || gateway.Zone() == r.Interface)
}

func (a *Adapter) save() error {
	path := filepath.Join(a.directory, "network-journal.json")
	if a.journal == nil || len(a.journal.Changes) == 0 {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return ErrJournal
		}
		return syncDirectory(a.directory)
	}
	encoded, err := json.Marshal(a.journal)
	if err != nil || len(encoded) > maxJournal {
		return ErrJournal
	}
	file, err := os.CreateTemp(a.directory, ".network-journal-*")
	if err != nil {
		return ErrJournal
	}
	name := file.Name()
	defer os.Remove(name)
	if err = file.Chmod(0600); err == nil {
		_, err = file.Write(encoded)
	}
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil || closeErr != nil || os.Rename(name, path) != nil {
		return ErrJournal
	}
	return syncDirectory(a.directory)
}

func syncDirectory(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return ErrJournal
	}
	defer file.Close()
	if file.Sync() != nil {
		return ErrJournal
	}
	return nil
}

func (a *Adapter) run(ctx context.Context, executable string, args ...string) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	output, err := a.runner.Run(ctx, executable, args...)
	if err != nil || len(output) > maxOutput {
		return nil, ErrCommand
	}
	return output, nil
}

// Discover uses the physical scoped default, which remains available while
// unscoped split defaults route application traffic into the utun.
func (a *Adapter) Discover(ctx context.Context) (Physical, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	var p Physical
	output, err := a.run(ctx, scutil, "--nwi")
	if err != nil {
		return p, ErrDiscover
	}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 4 && fields[1] == ":" && fields[2] == "flags" && strings.Contains(line, "IPv4") &&
			interfaceName.MatchString(fields[0]) && !strings.HasPrefix(fields[0], "utun") && fields[0] != "lo0" {
			p.Interface = fields[0]
			break
		}
	}
	if p.Interface == "" {
		output, err = a.run(ctx, routeTool, "-n", "get", "-inet", "default")
		if err != nil {
			return p, ErrDiscover
		}
		p.Interface = field(string(output), "interface")
	}
	if !interfaceName.MatchString(p.Interface) || strings.HasPrefix(p.Interface, "utun") || p.Interface == "lo0" {
		return p, ErrDiscover
	}
	output, err = a.run(ctx, routeTool, "-n", "get", "-inet", "-ifscope", p.Interface, "default")
	if err != nil || field(string(output), "interface") != p.Interface {
		return p, ErrDiscover
	}
	p.GatewayIPv4 = field(string(output), "gateway")
	if output, err = a.run(ctx, routeTool, "-n", "get", "-inet6", "-ifscope", p.Interface, "default"); err == nil && field(string(output), "interface") == p.Interface {
		p.GatewayIPv6 = field(string(output), "gateway")
	}
	services, err := a.services(ctx)
	if err != nil {
		return p, ErrDiscover
	}
	for _, service := range services {
		if service.Interface == p.Interface && !service.Disabled {
			p.Service = service.Name
			break
		}
	}
	if p.Service == "" {
		return p, ErrDiscover
	}
	p.DNS, err = a.configuredDNS(ctx, p.Service)
	if err != nil {
		return p, ErrDiscover
	}
	if a.journal != nil && a.journal.Physical.Interface == p.Interface && a.journal.Physical.Service == p.Service && equalDNS(p.DNS, []string{resolver}) {
		p.DNS = append([]string(nil), a.journal.Physical.DNS...)
	} else if len(p.DNS) == 0 {
		output, err = a.run(ctx, scutil, "--dns")
		if err != nil {
			return p, ErrDiscover
		}
		p.DNS = effectiveDNS(string(output), p.Interface)
	}
	if len(p.DNS) == 0 {
		return p, ErrDiscover
	}
	table, err := a.routes(ctx)
	if err != nil {
		return p, ErrDiscover
	}
	for _, r := range table {
		prefix, _ := netip.ParsePrefix(r.Prefix)
		// Bypass routes installed by Apply are not a new physical network.
		// Treating them as LAN makes the next health check look like a route
		// change, and startup restarts until the UI gives up while still "starting".
		if a.routeOwned(r) || a.journal != nil && r.Interface == a.journal.Tun {
			continue
		}
		if (privatePrefix(prefix) || r.ViaLink && r.Interface == p.Interface && prefix.Bits() > 0) && r.Interface != "lo0" {
			p.LANCIDRs = append(p.LANCIDRs, r.Prefix)
		}
	}
	p.LANCIDRs = unique(p.LANCIDRs)
	if !validPhysical(p) {
		return p, ErrDiscover
	}
	return p, nil
}

// Apply never replaces a pre-existing route. Every mutation has an intent on
// disk before execution; Restore can safely replay it after a partial failure.
func (a *Adapter) Apply(ctx context.Context, p Physical, utun string, serverIPs []string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !validPhysical(p) || !tunnelName.MatchString(utun) || len(serverIPs) > 32 {
		return ErrInvalid
	}
	serverIPs = append([]string(nil), serverIPs...)
	for i, value := range serverIPs {
		address, err := netip.ParseAddr(value)
		if err != nil || address.Zone() != "" || address.IsUnspecified() || netip.MustParsePrefix(fakePool).Contains(address) {
			return ErrInvalid
		}
		serverIPs[i] = address.Unmap().String()
	}
	serverIPs = unique(serverIPs)
	services, err := a.services(ctx)
	if err != nil {
		return err
	}
	serviceMatches := false
	for _, current := range services {
		if current.Name == p.Service && current.Interface == p.Interface && !current.Disabled {
			serviceMatches = true
		}
	}
	if !serviceMatches {
		return ErrChanged
	}
	table, err := a.routes(ctx)
	if err != nil {
		return err
	}
	table, err = a.reclaimLegacyTunnel(ctx, table, utun)
	if err != nil {
		return err
	}
	if err := a.conflicts(table, p, utun, serverIPs); err != nil {
		return err
	}
	if a.journal != nil {
		same := a.journal.Tun == utun && a.journal.Physical.Interface == p.Interface && a.journal.Physical.Service == p.Service &&
			a.journal.Physical.GatewayIPv4 == p.GatewayIPv4 && a.journal.Physical.GatewayIPv6 == p.GatewayIPv6 && reflect.DeepEqual(a.journal.ServerIPs, serverIPs)
		if same && a.installed(ctx, table) {
			return nil
		}
		if err := a.restore(ctx); err != nil {
			return err
		}
		table, err = a.routes(ctx)
		if err != nil {
			return err
		}
	}
	beforeDNS, err := a.configuredDNS(ctx, p.Service)
	if err != nil {
		return err
	}
	if equalDNS(beforeDNS, []string{resolver}) {
		// An unjournaled loopback override may belong to another DNS service.
		return ErrConflict
	}
	a.journal = &journal{Version: 1, Physical: p, Tun: utun, ServerIPs: serverIPs}
	fail := func(err error) error { return errors.Join(err, a.restore(ctx)) }
	for _, wanted := range desiredRoutes(p, utun, serverIPs) {
		if existing, ok := exactRoute(table, wanted.Prefix, wanted.Scoped); ok {
			prefix, _ := netip.ParsePrefix(wanted.Prefix)
			if privatePrefix(prefix) && wanted.Prefix != fakePool {
				continue // Existing LAN/mesh routes retain their original owner.
			}
			if !matches(existing, wanted) {
				return fail(ErrConflict)
			}
			continue
		}
		a.journal.Changes = append(a.journal.Changes, mutation{Kind: "route", Route: wanted})
		if err := a.save(); err != nil {
			return fail(err)
		}
		if _, err := a.run(ctx, routeTool, routeArgs("add", wanted)...); err != nil {
			return fail(err)
		}
		table = append(table, wanted)
	}
	a.journal.Changes = append(a.journal.Changes, mutation{Kind: "dns", Service: p.Service, Interface: p.Interface, BeforeDNS: beforeDNS})
	if err := a.save(); err != nil {
		return fail(err)
	}
	if _, err := a.run(ctx, networksetup, "-setdnsservers", p.Service, resolver); err != nil {
		return fail(err)
	}
	if err := a.flush(ctx); err != nil {
		return fail(err)
	}
	return nil
}

func (a *Adapter) installed(ctx context.Context, table []route) bool {
	for _, change := range a.journal.Changes {
		if change.Kind == "dns" {
			current, err := a.configuredDNS(ctx, change.Service)
			if err != nil || !equalDNS(current, []string{resolver}) {
				return false
			}
		} else if current, ok := exactRoute(table, change.Route.Prefix, change.Route.Scoped); !ok || !matches(current, change.Route) {
			return false
		}
	}
	return len(a.journal.Changes) != 0
}

func (a *Adapter) Reclaim(ctx context.Context) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	table, err := a.routes(ctx)
	if err != nil {
		return err
	}
	_, err = a.reclaimLegacyTunnel(ctx, table, "")
	return err
}

func (a *Adapter) Restore(ctx context.Context) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.restore(ctx)
}

func (a *Adapter) restore(ctx context.Context) error {
	if a.journal == nil {
		return nil
	}
	var failures []error
	changedDNS := false
	for i := len(a.journal.Changes) - 1; i >= 0; i-- {
		change := a.journal.Changes[i]
		var err error
		if change.Kind == "dns" {
			var exists bool
			serviceName := change.Service
			var services []service
			services, err = a.services(ctx)
			if err == nil {
				var renamed []string
				for _, current := range services {
					if current.Name == change.Service && current.Interface == change.Interface {
						exists = true
						break
					}
					if current.Interface == change.Interface {
						renamed = append(renamed, current.Name)
					}
				}
				if !exists && len(renamed) == 1 {
					// networksetup identifies services by name. A unique service on
					// the original device can have been renamed while connected.
					// Its DNS still has to match our value before restoration.
					serviceName, exists = renamed[0], true
				} else if !exists && len(renamed) > 1 {
					err = ErrChanged
				}
			}
			if err == nil && exists {
				var current []string
				current, err = a.configuredDNS(ctx, serviceName)
				if err == nil && equalDNS(current, []string{resolver}) {
					arguments := append([]string{"-setdnsservers", serviceName}, change.BeforeDNS...)
					if len(change.BeforeDNS) == 0 {
						arguments = append(arguments, "Empty")
					}
					_, err = a.run(ctx, networksetup, arguments...)
					changedDNS = changedDNS || err == nil
				}
			}
		} else {
			var table []route
			table, err = a.routes(ctx)
			if err == nil {
				if current, ok := exactRoute(table, change.Route.Prefix, change.Route.Scoped); ok && matches(current, change.Route) {
					_, err = a.run(ctx, routeTool, routeArgs("delete", change.Route)...)
				}
			}
		}
		if err != nil {
			failures = append(failures, err)
			continue
		}
		a.journal.Changes = append(a.journal.Changes[:i], a.journal.Changes[i+1:]...)
		if err := a.save(); err != nil {
			// Cleanup already happened. Keeping the durable intent is safe on retry.
			failures = append(failures, err)
			break
		}
	}
	if len(a.journal.Changes) == 0 {
		a.journal = nil
	}
	if changedDNS {
		failures = append(failures, a.flush(ctx))
	}
	return errors.Join(failures...)
}

func (a *Adapter) flush(ctx context.Context) error {
	_, first := a.run(ctx, "/usr/bin/dscacheutil", "-flushcache")
	_, second := a.run(ctx, "/usr/bin/killall", "-HUP", "mDNSResponder")
	return errors.Join(first, second)
}

// Steer sends ip through the physical gateway so a latency probe is not
// answered by the local tunnel stack. The active server bypass and LAN
// routes are left alone. The returned function removes only a route this
// call added; it still runs after ctx is cancelled.
func (a *Adapter) Steer(ctx context.Context, ip string) (func(), error) {
	address, err := netip.ParseAddr(ip)
	if err != nil || address.Zone() != "" {
		return nil, ErrInvalid
	}
	address = address.Unmap()
	if !address.Is4() || address.IsUnspecified() || address.IsLoopback() || address.IsMulticast() || address.IsLinkLocalUnicast() || netip.MustParsePrefix(fakePool).Contains(address) {
		return nil, ErrInvalid
	}
	noop := func() {}
	if address.IsPrivate() || netip.MustParsePrefix("100.64.0.0/10").Contains(address) {
		return noop, nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if a.journal == nil {
		return noop, nil
	}
	for _, lan := range a.journal.Physical.LANCIDRs {
		prefix, err := netip.ParsePrefix(lan)
		if err == nil && prefix.Contains(address) {
			return noop, nil
		}
	}
	for _, server := range a.journal.ServerIPs {
		if server == address.String() {
			return noop, nil
		}
	}
	gateway, err := netip.ParseAddr(a.journal.Physical.GatewayIPv4)
	if err != nil || !gateway.Is4() {
		return nil, ErrDiscover
	}
	wanted := route{Prefix: netip.PrefixFrom(address, 32).String(), Gateway: gateway.String(), Interface: a.journal.Physical.Interface}
	if !validRoute(wanted) {
		return nil, ErrInvalid
	}
	table, err := a.routes(ctx)
	if err != nil {
		return nil, err
	}
	if existing, ok := exactRoute(table, wanted.Prefix, false); ok {
		if matches(existing, wanted) {
			return noop, nil
		}
		return nil, ErrConflict
	}
	if len(a.journal.Changes) >= 60 {
		return nil, ErrConflict
	}
	a.journal.Changes = append(a.journal.Changes, mutation{Kind: "route", Route: wanted})
	if err := a.save(); err != nil {
		a.journal.Changes = a.journal.Changes[:len(a.journal.Changes)-1]
		return nil, err
	}
	if _, err := a.run(ctx, routeTool, routeArgs("add", wanted)...); err != nil {
		if _, changeErr := a.run(ctx, routeTool, routeArgs("change", wanted)...); changeErr != nil {
			a.journal.Changes = a.journal.Changes[:len(a.journal.Changes)-1]
			_ = a.save()
			return nil, err
		}
	}
	released := false
	return func() {
		a.mu.Lock()
		defer a.mu.Unlock()
		if released {
			return
		}
		released = true
		cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if table, err := a.routes(cleanup); err == nil {
			if current, ok := exactRoute(table, wanted.Prefix, false); ok && matches(current, wanted) {
				_, _ = a.run(cleanup, routeTool, routeArgs("delete", wanted)...)
			}
		}
		a.dropRouteChange(wanted)
		_ = a.save()
	}, nil
}

func (a *Adapter) dropRouteChange(wanted route) {
	if a.journal == nil {
		return
	}
	for i := len(a.journal.Changes) - 1; i >= 0; i-- {
		change := a.journal.Changes[i]
		if change.Kind == "route" && matches(change.Route, wanted) {
			a.journal.Changes = append(a.journal.Changes[:i], a.journal.Changes[i+1:]...)
			return
		}
	}
}

func routeArgs(action string, r route) []string {
	prefix := netip.MustParsePrefix(r.Prefix)
	family := "-inet"
	if prefix.Addr().Is6() {
		family = "-inet6"
	}
	args := []string{"-n", action, family, "-net", r.Prefix}
	if r.ViaLink {
		args = append(args, "-interface", r.Interface)
	} else {
		args = append(args, r.Gateway)
	}
	if r.Scoped {
		args = append(args, "-ifscope", r.Interface)
	}
	return args
}

func desiredRoutes(p Physical, utun string, serverIPs []string) []route {
	var result []route
	for _, ip := range serverIPs {
		address := netip.MustParseAddr(ip)
		alreadyLocal := false
		for _, lan := range p.LANCIDRs {
			alreadyLocal = alreadyLocal || netip.MustParsePrefix(lan).Contains(address)
		}
		if alreadyLocal {
			continue // Never replace an existing on-link/mesh route with the default gateway.
		}
		gateway, bits := p.GatewayIPv4, 32
		if address.Is6() {
			gateway, bits = p.GatewayIPv6, 128
		}
		result = append(result, route{Prefix: netip.PrefixFrom(address, bits).String(), Gateway: gateway, Interface: p.Interface, ViaLink: gateway == ""})
	}
	for _, prefix := range []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "fc00::/7", "fe80::/10"} {
		gateway := p.GatewayIPv4
		if netip.MustParsePrefix(prefix).Addr().Is6() {
			gateway = p.GatewayIPv6
		}
		result = append(result, route{Prefix: prefix, Gateway: gateway, Interface: p.Interface, ViaLink: gateway == ""})
	}
	for _, prefix := range []string{fakePool, "0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"} {
		result = append(result, route{Prefix: prefix, Interface: utun, ViaLink: true})
	}
	// IP_BOUND_IF does not override an unscoped split default on utun: the
	// bound socket gets "network is unreachable" for every other public
	// address. The same prefixes, scoped to the physical interface, are
	// consulted only by those bound sockets. Unscoped traffic stays in the tunnel.
	for _, prefix := range []string{"0.0.0.0/1", "128.0.0.0/1"} {
		result = append(result, route{Prefix: prefix, Gateway: p.GatewayIPv4, Interface: p.Interface, Scoped: true})
	}
	return result
}

// The previous matveev VPN used sing-box's default utun address. After that
// daemon is replaced, the interface can remain with no owner and block startup.
func (a *Adapter) reclaimLegacyTunnel(ctx context.Context, table []route, keep string) ([]route, error) {
	pool := netip.MustParsePrefix(fakePool)
	seen := map[string]bool{}
	reclaimed := false
	for _, candidate := range table {
		name := candidate.Interface
		if seen[name] || name == keep || !tunnelName.MatchString(name) {
			continue
		}
		prefix, err := netip.ParsePrefix(candidate.Prefix)
		if err != nil {
			continue
		}
		if prefix.Bits() != 0 && !pool.Contains(prefix.Addr()) && privatePrefix(prefix) {
			continue
		}
		seen[name] = true
		output, err := a.run(ctx, ifconfigTool, name)
		if err != nil || !strings.Contains(string(output), "inet 172.19.0.1") {
			continue
		}
		// The same address is used by other clients, including Sota Connect.
		// A live socket means that tunnel still has an owner; only an abandoned
		// interface is removed.
		if a.legacyTunnelActive(ctx) {
			continue
		}
		for _, r := range table {
			if r.Interface != name {
				continue
			}
			prefix, err := netip.ParsePrefix(r.Prefix)
			if err != nil || prefix.Bits() > 1 && !pool.Contains(prefix.Addr()) {
				continue
			}
			_, _ = a.run(ctx, routeTool, routeArgs("delete", r)...)
		}
		_, _ = a.run(ctx, ifconfigTool, name, "destroy")
		reclaimed = true
	}
	if !reclaimed {
		return table, nil
	}
	return a.routes(ctx)
}

func (a *Adapter) routeOwned(r route) bool {
	if a.journal == nil {
		return false
	}
	for _, change := range a.journal.Changes {
		if change.Kind == "route" && matches(r, change.Route) {
			return true
		}
	}
	return false
}

// legacyTunnelActive reports whether some process still owns the old
// 172.19.0.1 tunnel. netstat keeps the dotted local address after the process
// exits only until its sockets disappear, so an abandoned utun does not match.
func (a *Adapter) legacyTunnelActive(ctx context.Context) bool {
	output, err := a.run(ctx, netstat, "-an", "-f", "inet", "-p", "tcp")
	if err != nil {
		return true
	}
	return strings.Contains(string(output), "172.19.0.1.")
}

func (a *Adapter) conflicts(table []route, p Physical, utun string, serverIPs []string) error {
	pool := netip.MustParsePrefix(fakePool)
	for _, r := range table {
		if r.Scoped {
			// Another owner's ifscope split default would capture our bound
			// direct sockets. Routes recorded in the journal are removed and
			// replaced when the physical gateway changes, so they are not conflicts.
			if !a.routeOwned(r) && (r.Prefix == "0.0.0.0/1" || r.Prefix == "128.0.0.0/1") &&
				!matches(r, route{Prefix: r.Prefix, Gateway: p.GatewayIPv4, Interface: p.Interface, Scoped: true}) {
				return ErrConflict
			}
			continue
		}
		owned := false
		if a.journal != nil {
			for _, change := range a.journal.Changes {
				if change.Kind == "route" && matches(r, change.Route) {
					owned = true
					break
				}
			}
		}
		if owned {
			continue
		}
		prefix, _ := netip.ParsePrefix(r.Prefix)
		if prefix.Bits() > 0 && (pool.Contains(prefix.Addr()) || prefix.Contains(pool.Addr())) {
			return ErrConflict
		}
		// A default or split-default on another utun is another VPN. Cloned host
		// routes are only a routing cache and must not block startup.
		if strings.HasPrefix(r.Interface, "utun") && r.Interface != utun && prefix.Bits() <= 1 && !privatePrefix(prefix) {
			return ErrConflict
		}
		if prefix.Addr().Is6() && prefix.Bits() > 0 && !privatePrefix(prefix) {
			// A connected public prefix is still the actual local network.
			// Its on-link route on the selected physical interface is evidence,
			// unlike a gateway route installed by another VPN or route manager.
			if r.ViaLink && r.Interface == p.Interface {
				continue
			}
			local := false
			for _, lan := range p.LANCIDRs {
				localPrefix := netip.MustParsePrefix(lan)
				if localPrefix.Addr().Is6() && localPrefix.Bits() <= prefix.Bits() && localPrefix.Contains(prefix.Addr()) {
					local = true
				}
			}
			if local {
				continue
			}
			allowedUplink := false
			for _, ip := range serverIPs {
				address := netip.MustParseAddr(ip)
				if address.Is6() && prefix.Bits() == 128 && prefix.Addr() == address {
					allowedUplink = true
				}
			}
			if !allowedUplink {
				return ErrConflict
			}
		}
	}
	return nil
}

func privatePrefix(prefix netip.Prefix) bool {
	if !prefix.IsValid() || prefix.Bits() == 0 {
		return false
	}
	address := prefix.Addr()
	return address.IsPrivate() || address.IsLoopback() || address.IsLinkLocalUnicast() || address.IsMulticast() ||
		netip.MustParsePrefix("100.64.0.0/10").Contains(address)
}

func matches(current, wanted route) bool {
	return current.Prefix == wanted.Prefix && current.Interface == wanted.Interface && current.Scoped == wanted.Scoped &&
		(wanted.ViaLink || strings.EqualFold(current.Gateway, wanted.Gateway))
}

func exactRoute(table []route, prefix string, scoped bool) (route, bool) {
	for _, r := range table {
		if r.Prefix == prefix && r.Scoped == scoped {
			return r, true
		}
	}
	return route{}, false
}

func field(output, name string) string {
	for _, line := range strings.Split(output, "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), ":", 2)
		if len(parts) == 2 && parts[0] == name {
			return strings.TrimSpace(parts[1])
		}
	}
	return ""
}

type service struct {
	Name, Interface string
	Disabled        bool
}

func (a *Adapter) services(ctx context.Context) ([]service, error) {
	output, err := a.run(ctx, networksetup, "-listnetworkserviceorder")
	if err != nil {
		return nil, err
	}
	var result []service
	var pending service
	for _, raw := range strings.Split(string(output), "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "(") && !strings.HasPrefix(line, "(Hardware Port:") {
			close := strings.Index(line, ")")
			if close > 1 {
				name := strings.TrimSpace(line[close+1:])
				pending = service{Name: strings.TrimPrefix(name, "*"), Disabled: strings.HasPrefix(name, "*")}
			}
		} else if index := strings.Index(line, "Device:"); index >= 0 && pending.Name != "" {
			pending.Interface = strings.TrimSpace(strings.TrimSuffix(line[index+len("Device:"):], ")"))
			if interfaceName.MatchString(pending.Interface) {
				result = append(result, pending)
			}
			pending = service{}
		}
	}
	return result, nil
}

func (a *Adapter) configuredDNS(ctx context.Context, service string) ([]string, error) {
	output, err := a.run(ctx, networksetup, "-getdnsservers", service)
	if err != nil {
		return nil, err
	}
	text := strings.TrimSpace(string(output))
	if strings.HasPrefix(text, "There aren't any DNS Servers set on ") {
		return nil, nil
	}
	var servers []string
	for _, line := range strings.Split(text, "\n") {
		address, err := netip.ParseAddr(strings.TrimSpace(line))
		if err != nil || len(servers) == 16 {
			return nil, ErrDiscover
		}
		servers = append(servers, address.String())
	}
	return servers, nil
}

func effectiveDNS(output, physicalInterface string) []string {
	type block struct {
		addresses []string
		iface     string
	}
	var blocks []block
	var pending block
	finish := func() {
		if len(pending.addresses) != 0 {
			blocks = append(blocks, pending)
		}
		pending = block{}
	}
	for _, line := range strings.Split(output, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "resolver #") {
			finish()
		}
		if strings.HasPrefix(trimmed, "nameserver[") {
			if index := strings.Index(trimmed, ":"); index >= 0 {
				if address, err := netip.ParseAddr(strings.TrimSpace(trimmed[index+1:])); err == nil && !address.IsLoopback() {
					pending.addresses = append(pending.addresses, address.String())
				}
			}
		}
		if strings.HasPrefix(trimmed, "if_index") {
			start, end := strings.Index(trimmed, "("), strings.Index(trimmed, ")")
			if start >= 0 && end > start {
				pending.iface = trimmed[start+1 : end]
			}
		}
	}
	finish()
	for _, resolver := range blocks {
		if resolver.iface == physicalInterface {
			return unique(resolver.addresses)
		}
	}
	for _, resolver := range blocks {
		if resolver.iface == "" {
			return unique(resolver.addresses)
		}
	}
	return nil
}

func (a *Adapter) routes(ctx context.Context) ([]route, error) {
	var result []route
	for _, family := range []string{"inet", "inet6"} {
		output, err := a.run(ctx, netstat, "-rn", "-f", family)
		if err != nil {
			return nil, err
		}
		parsed, err := parseRoutes(string(output), family)
		if err != nil {
			return nil, err
		}
		result = append(result, parsed...)
	}
	return result, nil
}

func parseRoutes(output, family string) ([]route, error) {
	var result []route
	interfaceColumn := -1
	for _, raw := range strings.Split(output, "\n") {
		fields := strings.Fields(raw)
		if len(fields) == 0 {
			continue
		}
		if fields[0] == "Destination" {
			for index, name := range fields {
				if name == "Netif" || name == "Iface" {
					interfaceColumn = index
				}
			}
			continue
		}
		if interfaceColumn < 0 || len(fields) <= interfaceColumn || len(fields) < 4 {
			continue
		}
		if !interfaceName.MatchString(fields[interfaceColumn]) {
			return nil, ErrDiscover
		}
		prefix, err := routePrefix(fields[0], family)
		if err != nil {
			return nil, ErrDiscover
		}
		result = append(result, route{Prefix: prefix.String(), Gateway: fields[1], Interface: fields[interfaceColumn],
			ViaLink: strings.HasPrefix(fields[1], "link#"), Scoped: strings.Contains(fields[2], "I")})
	}
	if interfaceColumn < 0 {
		return nil, ErrDiscover
	}
	return result, nil
}

func routePrefix(value, family string) (netip.Prefix, error) {
	if value == "default" {
		if family == "inet6" {
			return netip.MustParsePrefix("::/0"), nil
		}
		return netip.MustParsePrefix("0.0.0.0/0"), nil
	}
	addressPart, suffix, hasPrefix := value, "", false
	if slash := strings.Index(value, "/"); slash >= 0 {
		addressPart, suffix, hasPrefix = value[:slash], value[slash+1:], true
	}
	if zone := strings.Index(addressPart, "%"); zone >= 0 {
		addressPart = addressPart[:zone]
	}
	if family == "inet" {
		parts := strings.Split(addressPart, ".")
		if len(parts) > 4 {
			return netip.Prefix{}, ErrDiscover
		}
		if !hasPrefix {
			suffix = fmt.Sprint(8 * len(parts))
		}
		for len(parts) < 4 {
			parts = append(parts, "0")
		}
		addressPart = strings.Join(parts, ".")
	} else if !hasPrefix {
		suffix = "128"
	}
	prefix, err := netip.ParsePrefix(addressPart + "/" + suffix)
	if err != nil {
		return netip.Prefix{}, err
	}
	return prefix.Masked(), nil
}

func unique(values []string) []string {
	result := append([]string(nil), values...)
	sort.Strings(result)
	if len(result) == 0 {
		return result
	}
	end := 1
	for _, value := range result[1:] {
		if value != result[end-1] {
			result[end] = value
			end++
		}
	}
	return result[:end]
}

func equalDNS(first, second []string) bool {
	return reflect.DeepEqual(unique(first), unique(second))
}
