// The service process owns accepted state, DNS, routes and the worker.
// Its only control surface is the private Unix socket.
package main

import (
	"context"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"matveevvpn/runtime/internal/ipc"
	"matveevvpn/runtime/internal/network"
	"matveevvpn/runtime/internal/service"
)

const defaultRoot = "/Library/Application Support/matveevVpn"

func main() {
	root := defaultRoot
	// A non-root process may use a private directory for tests. launchd runs as root
	// and ignores this variable so the installed service cannot be redirected.
	if os.Geteuid() != 0 {
		if dir := os.Getenv("MATVEEV_SERVICE_DIRECTORY"); filepath.IsAbs(dir) {
			root = dir
		}
	}
	if err := run(root); err != nil {
		os.Stderr.WriteString(err.Error() + "\n")
		os.Exit(1)
	}
}

func run(root string) error {
	ownerUID, ownerGID, err := readOwner(filepath.Join(root, "owner-uid"))
	if err != nil {
		return err
	}
	worker := filepath.Join(root, "bin", "matveev-xray-worker")
	if _, err := os.Stat(worker); err != nil {
		if exe, exeErr := os.Executable(); exeErr == nil {
			sibling := filepath.Join(filepath.Dir(exe), "matveev-xray-worker")
			if _, statErr := os.Stat(sibling); statErr == nil {
				worker = sibling
			}
		}
	}
	adapter, err := network.Open(filepath.Join(root, "network"), nil)
	if err != nil {
		return err
	}
	dnsAddress := "127.0.0.1:53"
	if os.Geteuid() != 0 {
		dnsAddress = "127.0.0.1:0"
	}
	bundleRecord := filepath.Join(root, "app-bundle")
	vpn, err := service.Open(service.Options{
		Directory:  filepath.Join(root, "state"),
		Binary:     worker,
		DNSAddress: dnsAddress,
		Network:    adapter,
		RulesFile:  filepath.Join(root, "rules", "hagezi-pro-mini.txt"),
		// Quitting the app leaves the bundle installed. Deleting it must not
		// leave a tunnel or DNS override behind with no way to turn it off.
		AppInstalled: func() bool { return service.BundleInstalled(bundleRecord) },
	})
	if err != nil {
		return err
	}
	defer vpn.Close()
	listener, err := ipc.Listen(filepath.Join(root, "ipc"))
	if err != nil {
		return err
	}
	if err := os.Chown(listener.Addr().String(), ownerUID, ownerGID); err != nil && os.Geteuid() == 0 {
		listener.Close()
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	return ipc.Serve(ctx, listener, vpn, ownerUID)
}

func readOwner(path string) (int, int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, 0, err
	}
	fields := strings.Fields(string(data))
	if len(fields) != 2 {
		return 0, 0, os.ErrInvalid
	}
	uid, err := strconv.Atoi(fields[0])
	if err != nil {
		return 0, 0, err
	}
	gid, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0, 0, err
	}
	return uid, gid, nil
}
