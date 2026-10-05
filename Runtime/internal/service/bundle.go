package service

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	defaultAppCheckInterval = time.Minute
	defaultAppMissingGrace  = 5 * time.Second
)

// BundleInstalled is true only for the app bundle path recorded at installation.
// The path is not secret. A missing, moved, or trashed bundle is not installed.
func BundleInstalled(recordPath string) bool {
	info, err := os.Lstat(recordPath)
	if err != nil || !info.Mode().IsRegular() || info.Size() == 0 || info.Size() > 4096 {
		return false
	}
	data, err := os.ReadFile(recordPath)
	if err != nil || bytes.Count(data, []byte("\n")) > 1 || bytes.Contains(data, []byte{0}) {
		return false
	}
	path := strings.TrimRight(string(data), "\n")
	if strings.TrimSpace(path) != path || filepath.Clean(path) != path || !filepath.IsAbs(path) {
		return false
	}
	if filepath.Ext(path) != ".app" || trashed(path) {
		return false
	}
	bundle, err := os.Lstat(path)
	if err != nil || !bundle.IsDir() {
		return false
	}
	executable := filepath.Join(path, "Contents", "MacOS", "matveevVpn")
	exe, err := os.Lstat(executable)
	if err != nil || !exe.Mode().IsRegular() || exe.Mode().Perm()&0111 == 0 {
		return false
	}
	return bundleIdentifier(filepath.Join(path, "Contents", "Info.plist")) == "com.matveev.vpn"
}

func trashed(path string) bool {
	for _, part := range strings.Split(path, string(os.PathSeparator)) {
		if part == ".Trash" || part == ".Trashes" {
			return true
		}
	}
	return false
}

func bundleIdentifier(plist string) string {
	info, err := os.Lstat(plist)
	if err != nil || !info.Mode().IsRegular() || info.Size() == 0 || info.Size() > 1<<20 {
		return ""
	}
	output, err := exec.Command("/usr/bin/plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", plist).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

// Sparkle replaces the bundle in place, so a short absence is not removal.
// A bundle that is already gone when the service starts does not get this grace.
func (s *Service) watchAppBundle() {
	if s.options.AppInstalled == nil {
		return
	}
	interval := s.options.AppCheckInterval
	if interval <= 0 {
		interval = defaultAppCheckInterval
	}
	grace := s.options.AppMissingGrace
	if grace <= 0 {
		grace = defaultAppMissingGrace
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	var absentSince time.Time
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			present := s.options.AppInstalled()
			s.mu.Lock()
			if s.closed {
				s.mu.Unlock()
				return
			}
			if present {
				absentSince = time.Time{}
				if s.appMissing {
					s.appMissing = false
					if s.accepted.DesiredOn && !s.disabled {
						s.reconcileLocked()
					}
				}
				s.mu.Unlock()
				continue
			}
			if absentSince.IsZero() {
				absentSince = time.Now()
			}
			if !s.appMissing && time.Since(absentSince) < grace {
				s.mu.Unlock()
				continue
			}
			s.appMissing = true
			state := s.status.RuntimeState
			if state != "off" && state != "stopping" {
				s.reconcileLocked()
			}
			s.mu.Unlock()
		}
	}
}
