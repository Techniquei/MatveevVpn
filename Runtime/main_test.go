package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/proxy"
)

const minimalConfig = `{"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}]}`

func send(t *testing.T, action, config string) response {
	t.Helper()
	command := request{Version: protocolVersion, ID: "test-1", Action: action}
	if config != "" {
		command.Config = json.RawMessage(config)
	}
	encoded, err := json.Marshal(command)
	if err != nil {
		t.Fatal(err)
	}
	return handle(encoded)
}

func cleanRuntime(t *testing.T) {
	t.Helper()
	if err := runtimeCore.stop(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = runtimeCore.stop() })
}

func TestProtocolRejectsUnknownFieldsAndTrailingJSON(t *testing.T) {
	cleanRuntime(t)
	for _, command := range []string{
		`{"version":1,"id":"a","action":"status","path":"private"}`,
		`{"version":1,"id":"a","action":"status"} {}`,
		`{"version":2,"id":"a","action":"status"}`,
		`{"version":1,"id":"","action":"status"}`,
	} {
		result := handle([]byte(command))
		if result.Success || result.Error != "invalid_request" {
			t.Fatalf("accepted invalid envelope: %+v", result)
		}
	}
	if result := send(t, "shell", ""); result.Error != "unknown_action" {
		t.Fatal(result)
	}
	if result := send(t, "status", `{}`); result.Error != "unexpected_config" {
		t.Fatal(result)
	}
}

func TestRequestLimitStopsReadingWithoutEchoingInput(t *testing.T) {
	var output bytes.Buffer
	err := serve(strings.NewReader(strings.Repeat("s", maximumRequestBytes+2)+"\n"), &output)
	if err == nil || output.Len() != 0 {
		t.Fatal("oversized input was not rejected cleanly")
	}
}

func TestManualTunProbeDoesNotConfigureSystemDNSOrDefaultRoutes(t *testing.T) {
	var config map[string]any
	if err := json.Unmarshal(tunSmokeConfig("utun900"), &config); err != nil {
		t.Fatal(err)
	}
	inbound := config["inbounds"].([]any)[0].(map[string]any)
	settings := inbound["settings"].(map[string]any)
	for _, key := range []string{"dns", "autoSystemRoutingTable", "autoSystemDnsToGateway", "autoOutboundsInterface"} {
		if _, exists := settings[key]; exists {
			t.Fatalf("passive probe changes system networking via %s", key)
		}
	}
	if _, exists := config["dns"]; exists {
		t.Fatal("passive probe contains DNS policy")
	}
}

func TestRejectedEngineConfigDoesNotLeakOrPublishRunning(t *testing.T) {
	cleanRuntime(t)
	const secret = "private-subscription-token"
	result := send(t, "start", `{"outbounds":[{"protocol":"`+secret+`"}]}`)
	encoded, _ := json.Marshal(result)
	if result.Success || result.Running || result.Error != "engine_rejected" || bytes.Contains(encoded, []byte(secret)) {
		t.Fatalf("unsafe rejection: %s", encoded)
	}
	if result := send(t, "start", minimalConfig); !result.Success || !result.Running {
		t.Fatal(result)
	}
}

func TestActiveCoreRejectsValidationWithoutChangingEnvironment(t *testing.T) {
	cleanRuntime(t)
	if result := send(t, "start", minimalConfig); !result.Success {
		t.Fatal(result)
	}
	const key = "MATVEEV_RUNTIME_VALIDATION_TEST"
	t.Setenv(key, "original")
	result := send(t, "validate", `{"env":{"`+key+`":"changed"},"outbounds":[{"protocol":"freedom"}]}`)
	if result.Error != "already_running" || !result.Running || os.Getenv(key) != "original" {
		t.Fatal(result)
	}
	if result := send(t, "start", minimalConfig); result.Error != "already_running" {
		t.Fatal(result)
	}
	if result := send(t, "stop", ""); !result.Success || result.Running {
		t.Fatal(result)
	}
	if result := send(t, "stop", ""); !result.Success {
		t.Fatal("stop is not idempotent")
	}
}

func TestRuntimeCarriesRealLoopbackTrafficAndReleasesListener(t *testing.T) {
	cleanRuntime(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "runtime-loopback-ok")
	}))
	defer server.Close()
	reserved, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := reserved.Addr().String()
	port := reserved.Addr().(*net.TCPAddr).Port
	reserved.Close()
	config := fmt.Sprintf(`{"inbounds":[{"listen":"127.0.0.1","port":%d,"protocol":"socks","settings":{"udp":true}}],"outbounds":[{"protocol":"freedom"}]}`, port)
	if result := send(t, "start", config); !result.Success || !result.Running {
		t.Fatal(result)
	}
	dialer, err := proxy.SOCKS5("tcp", address, nil, &net.Dialer{Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	transport := &http.Transport{DialContext: dialer.(proxy.ContextDialer).DialContext}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || string(body) != "runtime-loopback-ok" {
		t.Fatalf("actual transport failed: %q %v", body, err)
	}
	if result := send(t, "stop", ""); !result.Success || result.Running {
		t.Fatal(result)
	}
	listener, err := net.Listen("tcp4", address)
	if err != nil {
		t.Fatalf("stop retained the listener: %v", err)
	}
	listener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if connection, err := dialer.(proxy.ContextDialer).DialContext(ctx, "tcp", server.Listener.Addr().String()); err == nil {
		connection.Close()
		t.Fatal("stopped worker still carried traffic")
	}
}

func TestSupportedTransportsConstructWithoutStartingNetwork(t *testing.T) {
	cleanRuntime(t)
	for _, fixture := range []struct{ name, stream, flow string }{
		{"raw", `{"network":"raw","security":"none"}`, ""},
		{"tls", `{"network":"raw","security":"tls","tlsSettings":{"serverName":"example.com","fingerprint":"chrome"}}`, ""},
		{"ws", `{"network":"ws","security":"tls","wsSettings":{"path":"/vpn","headers":{"Host":"example.com"}},"tlsSettings":{"serverName":"example.com"}}`, ""},
		{"grpc", `{"network":"grpc","security":"tls","grpcSettings":{"serviceName":"vpn"},"tlsSettings":{"serverName":"example.com"}}`, ""},
		{"reality", `{"network":"raw","security":"reality","realitySettings":{"serverName":"example.com","fingerprint":"chrome","password":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","shortId":"0123456789abcdef"}}`, "xtls-rprx-vision"},
		{"xhttp-tls", `{"network":"xhttp","security":"tls","xhttpSettings":{"path":"/vpn","mode":"auto"},"tlsSettings":{"serverName":"example.com"}}`, ""},
		{"xhttp-reality", `{"network":"xhttp","security":"reality","xhttpSettings":{"path":"/vpn","mode":"auto"},"realitySettings":{"serverName":"example.com","fingerprint":"chrome","password":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","shortId":"0123456789abcdef"}}`, ""},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			config := fmt.Sprintf(`{"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":443,"users":[{"id":"11111111-1111-1111-1111-111111111111","encryption":"none","flow":%q}]}]},"streamSettings":%s}]}`, fixture.flow, fixture.stream)
			if result := send(t, "validate", config); !result.Success || result.Running {
				t.Fatal(result)
			}
		})
	}
}
