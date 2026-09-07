#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$(/usr/bin/mktemp -d /private/tmp/matveev-dns-test.XXXXXX)"
FAKE_NETWORKSETUP="$RUNTIME/networksetup"
CURRENT_DNS="$RUNTIME/current-dns"
CALL_LOG="$RUNTIME/calls"
trap '/bin/rm -rf "$RUNTIME"' EXIT

/bin/mkdir -p "$RUNTIME/run"
/usr/bin/printf '9.9.9.9\n149.112.112.112\n' > "$CURRENT_DNS"

/bin/cp /dev/null "$CALL_LOG"
/bin/cp "$ROOT_DIR/Tests/fake-networksetup" "$FAKE_NETWORKSETUP"
/bin/chmod 755 "$FAKE_NETWORKSETUP"

run_manager() {
  MATVEEV_BASE_DIR="$RUNTIME" \
  MATVEEV_NETWORKSETUP="$FAKE_NETWORKSETUP" \
  MATVEEV_DEFAULT_INTERFACE="test0" \
  MATVEEV_FAKE_DNS="$CURRENT_DNS" \
  MATVEEV_FAKE_LOG="$CALL_LOG" \
    "$ROOT_DIR/Resources/payload/dns-manager.sh" "$1"
}

run_manager apply
[[ "$(cat "$CURRENT_DNS")" == "198.18.0.2" ]]
[[ "$(sed -n '1p' "$RUNTIME/run/dns-state")" == "Test Network" ]]
[[ "$(sed -n '2p' "$RUNTIME/run/dns-state")" == "manual" ]]
[[ "$(tail -n +3 "$RUNTIME/run/dns-state")" == $'9.9.9.9\n149.112.112.112' ]]

# Applying twice must retain the original DNS backup, not the tunnel address.
run_manager apply
[[ "$(tail -n +3 "$RUNTIME/run/dns-state")" == $'9.9.9.9\n149.112.112.112' ]]

run_manager restore
[[ "$(cat "$CURRENT_DNS")" == $'9.9.9.9\n149.112.112.112' ]]
[[ ! -e "$RUNTIME/run/dns-state" ]]

# An initially automatic configuration must be restored with Empty.
: > "$CURRENT_DNS"
run_manager apply
run_manager restore
[[ ! -s "$CURRENT_DNS" ]]
[[ "$(tail -n 1 "$CALL_LOG")" == "Test Network|Empty" ]]

echo "dns manager: custom and automatic resolver restoration passed"
