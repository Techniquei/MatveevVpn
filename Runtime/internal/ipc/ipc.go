// Package ipc is the fixed local API of the VPN service.
// Callers cannot supply Xray JSON, filesystem paths, or shell commands.
package ipc

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/unix"
	"matveevvpn/runtime/internal/lists"
	"matveevvpn/runtime/internal/service"
)

const version = 1
const maximumMessageBytes = 1 << 20

type request struct {
	Version          int             `json:"version"`
	RequestID        string          `json:"requestID"`
	Action           string          `json:"action"`
	ExpectedRevision uint64          `json:"expectedRevision"`
	Payload          json.RawMessage `json:"payload,omitempty"`
}

type response struct {
	Version   int                 `json:"version"`
	RequestID string              `json:"requestID,omitempty"`
	Success   bool                `json:"success"`
	Status    service.Status      `json:"status"`
	Probes    []service.NodeProbe `json:"probes,omitempty"`
	Error     string              `json:"error,omitempty"`
}

type desiredPayload struct {
	DesiredOn bool `json:"desiredOn"`
}

type probePayload struct {
	NodeIDs []string `json:"nodeIDs,omitempty"`
}

// Listen creates the private socket. The directory is traversable but not listable.
func Listen(directory string) (net.Listener, error) {
	if err := os.MkdirAll(directory, 0711); err != nil {
		return nil, err
	}
	if err := os.Chmod(directory, 0711); err != nil {
		return nil, err
	}
	path := filepath.Join(directory, "service.sock")
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0600); err != nil {
		listener.Close()
		return nil, err
	}
	return listener, nil
}

// Serve accepts one request per connection. ownerUID is the installation owner.
// Root may connect during installation; every other UID must match the owner.
func Serve(ctx context.Context, listener net.Listener, vpn *service.Service, ownerUID int) error {
	if ownerUID < 0 {
		ownerUID = os.Geteuid()
	}
	go func() {
		<-ctx.Done()
		listener.Close()
	}()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go handleConn(conn, vpn, ownerUID)
	}
}

func handleConn(conn net.Conn, vpn *service.Service, ownerUID int) {
	defer conn.Close()
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return
	}
	uid, err := peerUID(unixConn)
	if err != nil || (uid != ownerUID && uid != 0) {
		writeResponse(conn, response{Version: version, Error: "unauthorized"})
		return
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	// Bound the entire message, rather than rejecting at the reader's 4 KiB
	// buffer boundary. A normal subscription can contain many more nodes.
	reader := bufio.NewReader(io.LimitReader(conn, maximumMessageBytes+1))
	line, err := reader.ReadBytes('\n')
	if err != nil || len(line) > maximumMessageBytes {
		writeResponse(conn, response{Version: version, Error: "invalid_request"})
		return
	}
	writeResponse(conn, dispatch(context.Background(), vpn, line[:len(line)-1]))
}

func dispatch(ctx context.Context, vpn *service.Service, line []byte) response {
	result := response{Version: version, Status: vpn.Status()}
	decoder := json.NewDecoder(bytes.NewReader(line))
	decoder.DisallowUnknownFields()
	var command request
	if len(line) > maximumMessageBytes || decoder.Decode(&command) != nil {
		result.Error = "invalid_request"
		return result
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF || command.Version != version || len(command.RequestID) == 0 || len(command.RequestID) > 64 {
		result.Error = "invalid_request"
		return result
	}
	result.RequestID = command.RequestID
	op, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	switch command.Action {
	case "GetStatus":
		if len(command.Payload) != 0 && string(command.Payload) != "null" {
			result.Error = "unexpected_payload"
			break
		}
		result.Status = vpn.Status()
	case "Apply":
		var intent lists.Intent
		if !decodePayload(command.Payload, &intent, &result) {
			break
		}
		status, err := vpn.ApplyIntent(op, command.RequestID, command.ExpectedRevision, intent)
		result.Status = status
		if err != nil {
			result.Error = safeError(err)
		}
	case "SetDesiredOn":
		var payload desiredPayload
		if !decodePayload(command.Payload, &payload, &result) {
			break
		}
		status, err := vpn.SetDesiredOn(op, command.RequestID, command.ExpectedRevision, payload.DesiredOn)
		result.Status = status
		if err != nil {
			result.Error = safeError(err)
		}
	case "ProbeNodes":
		var payload probePayload
		if len(command.Payload) != 0 && string(command.Payload) != "null" && !decodePayload(command.Payload, &payload, &result) {
			break
		}
		probes, err := vpn.ProbeNodes(op, payload.NodeIDs)
		result.Status = vpn.Status()
		result.Probes = probes
		if err != nil {
			result.Error = safeError(err)
		}
	default:
		result.Error = "unknown_action"
	}
	result.Success = result.Error == ""
	return result
}

func decodePayload(raw json.RawMessage, value any, result *response) bool {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if len(raw) == 0 || decoder.Decode(value) != nil {
		result.Error = "invalid_request"
		return false
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		result.Error = "invalid_request"
		return false
	}
	return true
}

func safeError(err error) string {
	switch err.Error() {
	case "invalid_snapshot", "no_selected_node", "operation_busy", "operation_cancelled", "request_id_conflict", "revision_conflict", "configuration_rejected", "persistence_failed", "service_closed":
		return err.Error()
	default:
		return "operation_failed"
	}
}

func writeResponse(conn net.Conn, result response) {
	_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	encoded, err := json.Marshal(result)
	if err != nil {
		encoded = []byte(`{"version":1,"success":false,"error":"operation_failed"}`)
	}
	_, _ = conn.Write(append(encoded, '\n'))
}

func peerUID(conn *net.UnixConn) (int, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var uid int
	var controlErr error
	err = raw.Control(func(fd uintptr) {
		cred, err := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		if err != nil {
			controlErr = err
			return
		}
		uid = int(cred.Uid)
	})
	if err != nil {
		return 0, err
	}
	return uid, controlErr
}
