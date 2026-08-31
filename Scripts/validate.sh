#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

/bin/bash -n "$ROOT_DIR/Resources/setup.command"
/bin/bash -n "$ROOT_DIR/Resources/uninstall.command"
/bin/bash -n "$ROOT_DIR/Resources/payload/controller.sh"
/bin/bash -n "$ROOT_DIR/Resources/payload/vpn-control.sh.template"
/usr/bin/ruby -c "$ROOT_DIR/Resources/payload/tools/build-config.rb" >/dev/null
/usr/bin/ruby -c "$ROOT_DIR/Resources/payload/tools/list-nodes.rb" >/dev/null
/usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$ROOT_DIR/Resources/payload/default-rules.json"
/usr/bin/plutil -lint "$ROOT_DIR/Resources/payload/com.matveev.vpn.plist" >/dev/null
/usr/bin/xcrun --sdk macosx swiftc -parse-as-library -typecheck -target arm64-apple-macos13.0 "$ROOT_DIR/Sources/matveevVpn.swift"
"$ROOT_DIR/Tests/controller-test.sh"

if /usr/bin/grep -Eq 'ByteCountFormatter|catmullRom|AreaMark' "$ROOT_DIR/Sources/matveevVpn.swift"; then
  echo "Unstable speed chart formatting was reintroduced." >&2
  exit 1
fi

echo "validation: ok"
