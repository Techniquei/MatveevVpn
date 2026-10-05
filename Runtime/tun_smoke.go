package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"time"

	"github.com/xtls/xray-core/core"
)

// This fixed, manual-only probe exists until the native service has its own
// acceptance harness. It creates a temporary interface, never default routes
// or system DNS, and accepts no user configuration.
func tunSmokeConfig(name string) []byte {
	config := map[string]any{
		"log": map[string]string{"loglevel": "none"},
		"inbounds": []any{map[string]any{
			"tag": "prototype-tun", "protocol": "tun",
			"settings": map[string]any{"name": name, "mtu": 1500, "gateway": []string{"169.254.250.1/30"}},
		}},
		"outbounds": []any{map[string]string{"protocol": "freedom", "tag": "direct"}},
	}
	encoded, _ := json.Marshal(config)
	return encoded
}

func runTunSmoke(output io.Writer) error {
	result := struct {
		Check     string `json:"check"`
		Core      string `json:"core"`
		Interface string `json:"interface,omitempty"`
		Created   bool   `json:"created"`
		Released  bool   `json:"released"`
		Error     string `json:"error,omitempty"`
	}{Check: "tun", Core: core.Version()}
	defer func() { _ = json.NewEncoder(output).Encode(result) }()
	if os.Geteuid() != 0 {
		result.Error = "administrator_required"
		return errors.New(result.Error)
	}
	for number := 900; number < 1000; number++ {
		name := fmt.Sprintf("utun%d", number)
		if _, err := net.InterfaceByName(name); err != nil {
			result.Interface = name
			break
		}
	}
	if result.Interface == "" {
		result.Error = "no_free_interface"
		return errors.New(result.Error)
	}
	if err := runtimeCore.construct(tunSmokeConfig(result.Interface), "", true); err != nil {
		result.Error = "tun_start_failed"
		return errors.New(result.Error)
	}
	_, err := net.InterfaceByName(result.Interface)
	result.Created = err == nil
	if err := runtimeCore.stop(); err != nil {
		result.Error = "tun_stop_failed"
		return errors.New(result.Error)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := net.InterfaceByName(result.Interface); err != nil {
			result.Released = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !result.Created || !result.Released {
		result.Error = "tun_lifecycle_failed"
		return errors.New(result.Error)
	}
	return nil
}
