package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/miekg/dns"
	"matveevvpn/runtime/internal/fakedns"
	"matveevvpn/runtime/internal/network"
	"matveevvpn/runtime/internal/service"
)

func TestSocketRoundTripKeepsTheWorkerIdleDuringProbes(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "mvpnipc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	listener, err := Listen(dir)
	if err != nil {
		t.Fatal(err)
	}
	var launches atomic.Int32
	vpn := openIdleService(t, &launches)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	defer vpn.Close()
	go Serve(ctx, listener, vpn, -1)

	socket := listener.Addr().String()
	status := call(t, socket, request{Version: version, RequestID: "status-1", Action: "GetStatus"})
	if !status.Success || status.Status.RuntimeState != "off" {
		t.Fatalf("status %+v", status)
	}
	applied := call(t, socket, request{
		Version: version, RequestID: "apply-1", Action: "Apply",
		Payload: json.RawMessage(`{"nodes":[{"id":"node-a","uri":"vless://11111111-1111-1111-1111-111111111111@server.test:443?encryption=none"}],"selectedNodeID":"node-a","mode":"selective","presets":["cursor"],"userDomains":["chosen.example"],"blockDomains":["ads.example"]}`),
	})
	if !applied.Success || applied.Status.AcceptedRevision != 1 {
		t.Fatalf("apply %+v", applied)
	}
	repeat := call(t, socket, request{
		Version: version, RequestID: "apply-1", Action: "Apply", ExpectedRevision: 0,
		Payload: json.RawMessage(`{"nodes":[{"id":"node-a","uri":"vless://11111111-1111-1111-1111-111111111111@server.test:443?encryption=none"}],"selectedNodeID":"node-a","mode":"selective","presets":["cursor"],"userDomains":["chosen.example"],"blockDomains":["ads.example"]}`),
	})
	if !repeat.Success || repeat.Status.AcceptedRevision != 1 {
		t.Fatalf("duplicate apply %+v", repeat)
	}
	conflict := call(t, socket, request{
		Version: version, RequestID: "apply-1", Action: "Apply", ExpectedRevision: 1,
		Payload: json.RawMessage(`{"mode":"all","nodes":[{"id":"node-a","uri":"vless://11111111-1111-1111-1111-111111111111@server.test:443?encryption=none"}],"selectedNodeID":"node-a"}`),
	})
	if conflict.Error != "request_id_conflict" {
		t.Fatalf("payload conflict %+v", conflict)
	}
	rejected := call(t, socket, request{Version: version, RequestID: "bad", Action: "Apply", Payload: json.RawMessage(`{"mode":"nope"}`)})
	if rejected.Success || rejected.Error != "invalid_snapshot" {
		t.Fatalf("unsafe apply %+v", rejected)
	}
	probes := call(t, socket, request{Version: version, RequestID: "probe-1", Action: "ProbeNodes", Payload: json.RawMessage(`{"nodeIDs":["node-a"]}`)})
	if !probes.Success || len(probes.Probes) != 1 || !probes.Probes[0].Reachable || probes.Probes[0].LatencyMilliseconds < 1 || launches.Load() != 0 {
		t.Fatalf("probe touched the worker or failed: %+v launches %d", probes, launches.Load())
	}
	off := call(t, socket, request{Version: version, RequestID: "off-1", Action: "SetDesiredOn", ExpectedRevision: 1, Payload: json.RawMessage(`{"desiredOn":false}`)})
	if !off.Success || off.Status.DesiredOn {
		t.Fatalf("off %+v", off)
	}
	unknown := call(t, socket, request{Version: version, RequestID: "unknown", Action: "shell"})
	if unknown.Error != "unknown_action" {
		t.Fatalf("unknown action %+v", unknown)
	}
	info, err := os.Lstat(socket)
	directory, dirErr := os.Lstat(dir)
	if err != nil || info.Mode().Perm() != 0600 || dirErr != nil || directory.Mode().Perm() != 0711 {
		t.Fatalf("socket permissions %v %v", info, directory)
	}
}

func TestSocketAcceptsLargeSubscriptionAndRejectsOversize(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "mvpnipc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	listener, err := Listen(dir)
	if err != nil {
		t.Fatal(err)
	}
	var launches atomic.Int32
	vpn := openIdleService(t, &launches)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go Serve(ctx, listener, vpn, -1)
	nodes := make([]map[string]string, 80)
	for i := range nodes {
		nodes[i] = map[string]string{"id": fmt.Sprintf("node-%d", i), "uri": fmt.Sprintf("vless://11111111-1111-1111-1111-111111111111@server-%d.test:443?encryption=none", i)}
	}
	payload, _ := json.Marshal(map[string]any{"nodes": nodes, "selectedNodeID": "node-0", "mode": "selective"})
	if len(payload) <= 4096 {
		t.Fatal("fixture must cross the reader buffer boundary")
	}
	result := call(t, listener.Addr().String(), request{Version: version, RequestID: "large", Action: "Apply", Payload: payload})
	if !result.Success || result.Status.AcceptedRevision != 1 || launches.Load() != 0 {
		t.Fatalf("large stopped subscription: %+v launches=%d", result, launches.Load())
	}
	conn, err := net.Dial("unix", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	// One byte above the bound must fail without waiting for EOF or a newline.
	_, _ = conn.Write([]byte(strings.Repeat(" ", maximumMessageBytes+1)))
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		t.Fatal(err)
	}
	var rejected response
	if json.Unmarshal(line, &rejected) != nil || rejected.Success || rejected.Error != "invalid_request" {
		t.Fatalf("oversized request: %s", line)
	}
	if vpn.Status().AcceptedRevision != 1 {
		t.Fatal("rejected request changed accepted state")
	}
}

func call(t *testing.T, path string, command request) response {
	t.Helper()
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	encoded, _ := json.Marshal(command)
	if _, err = conn.Write(append(encoded, '\n')); err != nil {
		t.Fatal(err)
	}
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		t.Fatal(err)
	}
	var result response
	if json.Unmarshal(line, &result) != nil {
		t.Fatalf("response %s", line)
	}
	return result
}

func openIdleService(t *testing.T, launches *atomic.Int32) *service.Service {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	vpn, err := service.Open(service.Options{
		Directory:  dir,
		DNSAddress: "127.0.0.1:0",
		Network:    idleNetwork{},
		Launch: func(string, string, string) (service.RuntimeProcess, error) {
			launches.Add(1)
			return &idleWorker{done: make(chan struct{})}, nil
		},
		Validate:       func(context.Context, string, string, string, []byte) error { return nil },
		Resolver:       func(network.Physical) (service.Transport, error) { return idleTransport{}, nil },
		Watch:          func(context.Context) (<-chan struct{}, error) { return make(chan struct{}), nil },
		HealthInterval: time.Hour,
		RetryInterval:  time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { vpn.Close() })
	return vpn
}

type idleNetwork struct{}

func (idleNetwork) Discover(context.Context) (network.Physical, error) {
	return network.Physical{Interface: "en0", GatewayIPv4: "192.0.2.1", Service: "Wi-Fi", DNS: []string{"192.0.2.53"}}, nil
}
func (idleNetwork) Apply(context.Context, network.Physical, string, []string) error { return nil }
func (idleNetwork) Restore(context.Context) error                                   { return nil }
func (idleNetwork) Reclaim(context.Context) error                                   { return nil }

type idleTransport struct{}

func (idleTransport) Resolve(context.Context, *dns.Msg, fakedns.Action) (*dns.Msg, error) {
	return nil, service.ErrResolver
}
func (idleTransport) Bootstrap(context.Context, string) ([]string, error) {
	return []string{"203.0.113.10"}, nil
}
func (idleTransport) Probe(context.Context, bool) error      { return nil }
func (idleTransport) ProbeTCP(context.Context, string) error { return nil }
func (idleTransport) Close()                                 {}

type idleWorker struct{ done chan struct{} }

func (w *idleWorker) Call(context.Context, string, []byte, string) (service.WorkerReply, error) {
	return service.WorkerReply{Version: 1, ID: "worker", Success: true, Running: true, Core: "test"}, nil
}
func (w *idleWorker) Done() <-chan struct{} { return w.done }
func (w *idleWorker) Close() error          { return nil }
