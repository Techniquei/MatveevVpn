#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(/usr/bin/mktemp -d /private/tmp/matveev-validation.XXXXXX)"
trap '/bin/rm -rf "$TEST_BUILD"' EXIT

/bin/bash -n "$ROOT_DIR/Resources/payload/uninstall-service.sh"
/bin/bash -n "$ROOT_DIR/Resources/payload/controller.sh"
/usr/bin/ruby -c "$ROOT_DIR/Resources/payload/tools/build-config.rb" >/dev/null
/usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$ROOT_DIR/Resources/payload/default-rules.json"
/usr/bin/plutil -lint "$ROOT_DIR/Resources/payload/com.matveev.vpn.plist" >/dev/null
/usr/bin/xcrun --sdk macosx swiftc -parse-as-library -typecheck -target arm64-apple-macos13.0 "$ROOT_DIR"/Sources/*.swift
"$ROOT_DIR/Tests/controller-test.sh"
/usr/bin/xcrun swiftc "$ROOT_DIR/Sources/Configuration.swift" "$ROOT_DIR/Tests/ConfigurationTests.swift" -o "$TEST_BUILD/configuration-tests"
"$TEST_BUILD/configuration-tests"
/usr/bin/xcrun swiftc "$ROOT_DIR/Sources/Configuration.swift" "$ROOT_DIR/Sources/SystemService.swift" "$ROOT_DIR/Sources/ConfigurationCoordinator.swift" "$ROOT_DIR/Tests/CoordinatorTests.swift" -o "$TEST_BUILD/coordinator-tests"
"$TEST_BUILD/coordinator-tests"
/usr/bin/ruby "$ROOT_DIR/Tests/routing-test.rb"
/bin/bash -n "$ROOT_DIR/Resources/payload/install-service.sh"

if /usr/bin/grep -Eq 'ByteCountFormatter|catmullRom|AreaMark' "$ROOT_DIR/Sources/matveevVpn.swift"; then
  echo "Unstable speed chart formatting was reintroduced." >&2
  exit 1
fi

echo "validation: ok"
