package network

import (
	"context"
	"net"
	"strings"
	"syscall"
	"time"
)

// PhysicalBind selects this interface. Unscoped 0/1 and 128/1 tunnel routes
// are more specific than the physical default, so a bound socket reaches
// other public addresses only when Apply has installed matching ifscope
// routes via the physical gateway. Adapter.Steer adds a temporary host
// route for the same reason while those ifscope routes are absent. The
// caller supplies a numeric address or an independent resolver.
func PhysicalBind(name string) (func(string, string, syscall.RawConn) error, error) {
	if !interfaceName.MatchString(name) || strings.HasPrefix(name, "utun") || name == "lo0" {
		return nil, ErrInvalid
	}
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return nil, ErrDiscover
	}
	return func(network, address string, raw syscall.RawConn) error {
		level, option := syscall.IPPROTO_IP, syscall.IP_BOUND_IF
		if strings.HasSuffix(network, "6") {
			level, option = syscall.IPPROTO_IPV6, syscall.IPV6_BOUND_IF
		} else if !strings.HasSuffix(network, "4") {
			return ErrInvalid
		}
		var socketError error
		if err := raw.Control(func(fd uintptr) { socketError = syscall.SetsockoptInt(int(fd), level, option, iface.Index) }); err != nil {
			return err
		}
		return socketError
	}, nil
}

// Watch coalesces AF_ROUTE notifications in a single-slot channel. The socket
// is nonblocking: cancellation cannot leave a goroutine in an unbounded Read.
func Watch(ctx context.Context) (<-chan struct{}, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	// Child launches use the same fork lock, so no worker inherits this socket
	// during the gap between socket creation and setting close-on-exec.
	syscall.ForkLock.RLock()
	fd, err := syscall.Socket(syscall.AF_ROUTE, syscall.SOCK_RAW, 0)
	if err == nil {
		syscall.CloseOnExec(fd)
	}
	syscall.ForkLock.RUnlock()
	if err != nil {
		return nil, ErrDiscover
	}
	if syscall.SetNonblock(fd, true) != nil || syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, 64<<10) != nil {
		_ = syscall.Close(fd)
		return nil, ErrDiscover
	}
	events := make(chan struct{}, 1)
	go func() {
		defer close(events)
		defer syscall.Close(fd)
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		buffer := make([]byte, 16<<10)
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
			dirty := false
			for count := 0; count < 32; count++ {
				n, err := syscall.Read(fd, buffer)
				if err == syscall.EAGAIN || err == syscall.EWOULDBLOCK {
					break
				}
				if err != nil {
					if err == syscall.EINTR {
						continue
					}
					return
				}
				dirty = dirty || n > 0
			}
			if dirty {
				select {
				case events <- struct{}{}:
				default:
				}
			}
		}
	}()
	return events, nil
}
