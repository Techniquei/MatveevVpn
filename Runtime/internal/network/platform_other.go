//go:build !darwin

package network

import (
	"context"
	"syscall"
)

func PhysicalBind(string) (func(string, string, syscall.RawConn) error, error) {
	return nil, ErrInvalid
}

func Watch(context.Context) (<-chan struct{}, error) { return nil, ErrDiscover }
