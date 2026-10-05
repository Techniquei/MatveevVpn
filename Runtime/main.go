// The worker is an internal child process, not the privileged service endpoint.
// Its parent owns deadlines, system network changes and configuration admission.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/xtls/xray-core/core"
)

const protocolVersion = 1
const maximumRequestBytes = 1 << 20

type request struct {
	Version          int             `json:"version"`
	ID               string          `json:"id"`
	Action           string          `json:"action"`
	Config           json.RawMessage `json:"config,omitempty"`
	FakeDNSDirectory string          `json:"fakeDNSDirectory,omitempty"`
}

type response struct {
	Version int    `json:"version"`
	ID      string `json:"id,omitempty"`
	Success bool   `json:"success"`
	Running bool   `json:"running"`
	Core    string `json:"core"`
	Error   string `json:"error,omitempty"`
}

func handle(input []byte) response {
	result := response{Version: protocolVersion, Core: core.Version(), Running: runtimeCore.running()}
	var command request
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.DisallowUnknownFields()
	if len(input) > maximumRequestBytes || decoder.Decode(&command) != nil {
		result.Error = "invalid_request"
		return result
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF || command.Version != protocolVersion ||
		len(command.ID) == 0 || len(command.ID) > 64 {
		result.Error = "invalid_request"
		return result
	}
	result.ID = command.ID
	if command.Action != "start" && command.Action != "validate" &&
		(len(command.Config) != 0 || command.FakeDNSDirectory != "") {
		result.Error = "unexpected_config"
		return result
	}
	var err error
	switch command.Action {
	case "start", "validate":
		// Validation constructors change process-global state. An active worker
		// must never validate a different config beside its managed instance.
		if runtimeCore.running() {
			result.Error = "already_running"
			break
		}
		var config map[string]json.RawMessage
		if json.Unmarshal(command.Config, &config) != nil || config == nil {
			result.Error = "invalid_config"
			break
		}
		// Native engine logs are not protocol responses and may contain secrets.
		// The prototype keeps them disabled; diagnostics belong to its parent.
		config["log"] = json.RawMessage(`{"loglevel":"none"}`)
		encoded, _ := json.Marshal(config)
		err = runtimeCore.construct(encoded, command.FakeDNSDirectory, command.Action == "start")
	case "stop":
		err = runtimeCore.stop()
	case "status":
	default:
		result.Error = "unknown_action"
	}
	if err != nil {
		// Upstream errors can contain server names or configuration values.
		result.Error = "engine_rejected"
	}
	result.Running = runtimeCore.running()
	result.Success = result.Error == ""
	return result
}

func serve(input io.Reader, output io.Writer) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), maximumRequestBytes+1)
	encoder := json.NewEncoder(output)
	for scanner.Scan() {
		if err := encoder.Encode(handle(scanner.Bytes())); err != nil {
			return err
		}
	}
	if scanner.Err() != nil {
		return errors.New("request_limit_or_read_failure")
	}
	return nil
}

func main() {
	tunCheck := len(os.Args) == 2 && os.Args[1] == "--tun-smoke"
	if len(os.Args) != 1 && !tunCheck {
		os.Exit(2)
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	done := make(chan error, 1)
	go func() {
		if tunCheck {
			done <- runTunSmoke(os.Stdout)
		} else {
			done <- serve(os.Stdin, os.Stdout)
		}
	}()
	var deadline <-chan time.Time
	if tunCheck {
		deadline = time.After(10 * time.Second)
	}
	exitCode := 0
	select {
	case err := <-done:
		if err != nil {
			exitCode = 1
		}
	case <-signals:
	case <-deadline:
		exitCode = 1
	}
	stopped := make(chan struct{})
	go func() { _ = runtimeCore.stop(); close(stopped) }()
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		exitCode = 1
	}
	os.Exit(exitCode)
}
