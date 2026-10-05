package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"matveevvpn/runtime/internal/fakedns"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/features/dns"
)

func freeTCPPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	return port
}

func freeUDPPort(t *testing.T) int {
	t.Helper()
	listener, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.LocalAddr().(*net.UDPAddr).Port
	listener.Close()
	return port
}

func TestPersistentReverseHolderUsesCurrentRecordsWithoutAllocation(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "table")
	store, err := fakedns.Open(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	holder := &persistentReverseHolder{directory: directory}
	if holder.Type() != (*dns.FakeDNSEngine)(nil) {
		t.Fatal("holder registered under an incompatible feature type")
	}
	if holder.GetFakeIPForDomain("loopback.test") != nil ||
		holder.GetFakeIPForDomain3("loopback.test", true, true) != nil {
		t.Fatal("the child allocated independently of the service")
	}
	unknown := xnet.ParseAddress("198.18.0.1")
	if domain := holder.GetDomainFromFakeDNS(unknown); domain != "" {
		t.Fatal("unknown synthetic destination was invented")
	}
	ip, err := store.Allocate("loopback.test")
	if err != nil {
		t.Fatal(err)
	}
	address := xnet.ParseAddress(ip.String())
	if domain := holder.GetDomainFromFakeDNS(address); domain != "loopback.test" {
		t.Fatalf("record published after holder creation remained invisible: %q", domain)
	}
	for _, fixture := range []struct {
		address string
		inPool  bool
	}{
		{"198.18.0.0", true}, {"198.19.255.255", true},
		{"198.20.0.0", false}, {"192.168.1.1", false},
		{"2001:2::1", false}, {"loopback.test", false},
	} {
		if got := holder.IsIPInIPPool(xnet.ParseAddress(fixture.address)); got != fixture.inPool {
			t.Fatalf("incorrect pool membership for %s", fixture.address)
		}
	}
}

func TestCustomHolderRejectsBuiltinFakeDNSBeforeConstruction(t *testing.T) {
	cleanRuntime(t)
	for _, config := range []string{
		`{"fakeDns":[{"ipPool":"198.18.0.0/15","poolSize":1}]}`,
		`{"FAKEDNS":[]}`,
		`{"dns":{"servers":["fakedns"]}}`,
		`{"dns":{"servers":[{"address":"fakedns"}]}}`,
	} {
		if err := runtimeCore.construct([]byte(config), t.TempDir(), false); err == nil {
			t.Fatalf("accepted second FakeDNS allocator: %s", config)
		}
	}
	if err := runtimeCore.construct([]byte(minimalConfig), "relative-private-path", false); err == nil {
		t.Fatal("accepted a caller-working-directory-dependent table path")
	}
}

func TestFailedStartClosesAlreadyStartedListenersAndAllowsNewInstance(t *testing.T) {
	cleanRuntime(t)
	occupied, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	first := freeTCPPort(t)
	second := occupied.Addr().(*net.TCPAddr).Port
	config := fmt.Sprintf(`{"inbounds":[{"listen":"127.0.0.1","port":%d,"protocol":"socks"},{"listen":"127.0.0.1","port":%d,"protocol":"socks"}],"outbounds":[{"protocol":"freedom"}]}`, first, second)
	if result := send(t, "start", config); result.Success || result.Running {
		t.Fatalf("partially failed instance was published: %+v", result)
	}
	released, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", first))
	if err != nil {
		t.Fatalf("failed Start did not close earlier listener: %v", err)
	}
	released.Close()
	if result := send(t, "start", minimalConfig); !result.Success || !result.Running {
		t.Fatalf("failed instance was reused or retained: %+v", result)
	}
}

// Both transports carry real packets through the dispatcher; static core DNS
// hosts keep all resolution and traffic on loopback without a host TUN.
func TestPersistentFakeDNSRestoresTCPAndUDPBeforeRoutingAcrossKilledCoreRestart(t *testing.T) {
	cleanRuntime(t)
	store, err := fakedns.Open(filepath.Join(t.TempDir(), "table"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	fakeIP, err := store.Allocate("loopback.test")
	if err != nil {
		t.Fatal(err)
	}
	unknownIP := netip.MustParseAddr("198.19.255.254")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, "fake-dns-tcp-ok")
	}))
	defer server.Close()
	udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	go func() {
		buffer := make([]byte, 512)
		for {
			n, peer, err := udp.ReadFrom(buffer)
			if err != nil {
				return
			}
			_, _ = udp.WriteTo(append([]byte("fake-dns-udp:"), buffer[:n]...), peer)
		}
	}()
	tcpPort, udpPort, missingUDPPort := freeTCPPort(t), freeUDPPort(t), freeUDPPort(t)
	config := fakeDNSLoopbackConfig(fakeIP.String(), unknownIP.String(), tcpPort, udpPort, missingUDPPort,
		server.Listener.Addr().(*net.TCPAddr).Port, udp.LocalAddr().(*net.UDPAddr).Port)
	encoded, _ := json.Marshal(request{Version: protocolVersion, ID: "persistent", Action: "validate", Config: config, FakeDNSDirectory: store.Directory()})
	if result := handle(encoded); !result.Success || result.Running {
		t.Fatalf("holder validation failed: %+v", result)
	}
	// The writer does not need to run beside the child for existing mappings to
	// remain available; reverse lookup reads only immutable private records.
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	for restart := 0; restart < 2; restart++ {
		child := startCoreTestChild(t, request{Version: protocolVersion, ID: "persistent", Action: "start", Config: config, FakeDNSDirectory: store.Directory()})
		client := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
		reply, err := client.Get(fmt.Sprintf("http://127.0.0.1:%d/", tcpPort))
		if err != nil {
			t.Fatalf("TCP metadata restore %d: %v", restart, err)
		}
		body, err := io.ReadAll(reply.Body)
		reply.Body.Close()
		if err != nil || string(body) != "fake-dns-tcp-ok" {
			t.Fatalf("TCP destination was not restored before IP guard: %q %v", body, err)
		}
		connection, err := net.Dial("udp4", fmt.Sprintf("127.0.0.1:%d", udpPort))
		if err != nil {
			t.Fatal(err)
		}
		connection.SetDeadline(time.Now().Add(3 * time.Second))
		_, err = connection.Write([]byte("packet"))
		buffer := make([]byte, 512)
		n, readErr := connection.Read(buffer)
		connection.Close()
		if err != nil || readErr != nil || string(buffer[:n]) != "fake-dns-udp:packet" {
			t.Fatalf("UDP metadata restore %d: %q %v %v", restart, buffer[:n], err, readErr)
		}
		missing, err := net.Dial("udp4", fmt.Sprintf("127.0.0.1:%d", missingUDPPort))
		if err != nil {
			t.Fatal(err)
		}
		missing.SetDeadline(time.Now().Add(200 * time.Millisecond))
		_, _ = missing.Write([]byte("unknown-synthetic"))
		_, err = missing.Read(buffer)
		missing.Close()
		if err == nil {
			t.Fatal("unknown synthetic address escaped the IP guard")
		}
		child.kill(t)
	}
}

// Re-executes the test binary as the actual worker main, keeping the process
// boundary test independent of a prebuilt binary and its build directory.
func TestCoreProcessHelper(t *testing.T) {
	if os.Getenv("MATVEEV_CORE_TEST_HELPER") != "1" {
		return
	}
	os.Args = os.Args[:1]
	main()
}

type coreTestChild struct {
	command     *exec.Cmd
	input       io.WriteCloser
	diagnostics *bytes.Buffer
	waited      bool
}

func startCoreTestChild(t *testing.T, command request) *coreTestChild {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	process := exec.Command(executable, "-test.run=^TestCoreProcessHelper$")
	process.Env = append(os.Environ(), "MATVEEV_CORE_TEST_HELPER=1")
	input, err := process.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := process.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	diagnostics := new(bytes.Buffer)
	process.Stderr = diagnostics
	if err := process.Start(); err != nil {
		t.Fatal(err)
	}
	child := &coreTestChild{command: process, input: input, diagnostics: diagnostics}
	t.Cleanup(func() {
		if !child.waited {
			_ = process.Process.Kill()
			_ = process.Wait()
		}
		input.Close()
	})
	if err := json.NewEncoder(input).Encode(command); err != nil {
		t.Fatal(err)
	}
	completed := make(chan error, 1)
	var reply response
	var firstLine []byte
	go func() {
		firstLine, err = bufio.NewReader(output).ReadBytes('\n')
		if err == nil {
			err = json.Unmarshal(firstLine, &reply)
		}
		completed <- err
	}()
	select {
	case err := <-completed:
		if err != nil || !reply.Success || !reply.Running {
			t.Fatalf("child activation failed: %+v %v (%q)", reply, err, firstLine)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("child activation exceeded bounded loopback test budget")
	}
	return child
}

func (c *coreTestChild) kill(t *testing.T) {
	t.Helper()
	if err := c.command.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	if err := c.command.Wait(); err == nil {
		t.Fatal("SIGKILL was not reflected in child termination")
	}
	c.waited = true
	if c.diagnostics.Len() != 0 {
		t.Fatal("child emitted an unstructured engine diagnostic")
	}
}

func fakeDNSLoopbackConfig(fakeIP, unknownIP string, tcp, udp, missingUDP, targetTCP, targetUDP int) []byte {
	inbound := func(tag, network, address string, port, targetPort int) map[string]any {
		return map[string]any{
			"tag": tag, "listen": "127.0.0.1", "port": port, "protocol": "dokodemo-door",
			"settings": map[string]any{"address": address, "port": targetPort, "network": network},
			"sniffing": map[string]any{"enabled": true, "metadataOnly": true, "destOverride": []string{"fakedns"}},
		}
	}
	config := map[string]any{
		"dns":       map[string]any{"hosts": map[string]string{"loopback.test": "127.0.0.1"}},
		"inbounds":  []any{inbound("tcp", "tcp", fakeIP, tcp, targetTCP), inbound("udp", "udp", fakeIP, udp, targetUDP), inbound("unknown", "udp", unknownIP, missingUDP, targetUDP)},
		"outbounds": []any{map[string]any{"protocol": "blackhole", "tag": "block"}, map[string]any{"protocol": "freedom", "tag": "direct", "settings": map[string]string{"domainStrategy": "UseIPv4"}}},
		"routing": map[string]any{"domainStrategy": "AsIs", "rules": []any{
			map[string]any{"type": "field", "ip": []string{"198.18.0.0/15"}, "outboundTag": "block"},
			map[string]any{"type": "field", "domain": []string{"full:loopback.test"}, "outboundTag": "direct"},
		}},
	}
	encoded, _ := json.Marshal(config)
	return encoded
}
