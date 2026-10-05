package service

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAppBundleCheckDefaultsToOnceAMinute(t *testing.T) {
	if defaultAppCheckInterval != time.Minute {
		t.Fatalf("app bundle check interval = %s", defaultAppCheckInterval)
	}
}

func TestBundleInstalledRequiresTheRecordedApp(t *testing.T) {
	root := t.TempDir()
	record := filepath.Join(root, "app-bundle")
	if BundleInstalled(record) {
		t.Fatal("missing record counted as installed")
	}
	app := writeAppBundle(t, filepath.Join(root, "matveevVpn.app"), "com.matveev.vpn")
	if err := os.WriteFile(record, []byte(app+"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if !BundleInstalled(record) {
		t.Fatal("recorded bundle was rejected")
	}
	if err := os.RemoveAll(app); err != nil {
		t.Fatal(err)
	}
	if BundleInstalled(record) {
		t.Fatal("deleted bundle still counted as installed")
	}
}

func TestBundleInstalledRejectsLookalikes(t *testing.T) {
	root := t.TempDir()
	record := filepath.Join(root, "app-bundle")
	valid := writeAppBundle(t, filepath.Join(root, "matveevVpn.app"), "com.matveev.vpn")
	cases := []string{
		writeAppBundle(t, filepath.Join(root, "other.app"), "com.example.other"),
		writeAppBundle(t, filepath.Join(root, ".Trash", "matveevVpn.app"), "com.matveev.vpn"),
		valid + "/../matveevVpn.app",
		"matveevVpn.app",
	}
	linked := filepath.Join(root, "linked.app")
	if err := os.Symlink(valid, linked); err != nil {
		t.Fatal(err)
	}
	cases = append(cases, linked)
	for _, path := range cases {
		if err := os.WriteFile(record, []byte(path+"\n"), 0644); err != nil {
			t.Fatal(err)
		}
		if BundleInstalled(record) {
			t.Fatalf("accepted %s", path)
		}
	}
}

func writeAppBundle(t *testing.T, app, identifier string) string {
	t.Helper()
	macOS := filepath.Join(app, "Contents", "MacOS")
	if err := os.MkdirAll(macOS, 0755); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(macOS, "matveevVpn")
	if err := os.WriteFile(executable, []byte("#!/bin/sh\n"), 0755); err != nil {
		t.Fatal(err)
	}
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>` + identifier + `</string></dict></plist>
`
	if err := os.WriteFile(filepath.Join(app, "Contents", "Info.plist"), []byte(plist), 0644); err != nil {
		t.Fatal(err)
	}
	return app
}
