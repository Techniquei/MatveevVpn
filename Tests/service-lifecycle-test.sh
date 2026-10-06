#!/bin/bash

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$(/usr/bin/mktemp -d /private/tmp/matveev-launchctl-test.XXXXXX)"
trap '/bin/rm -rf "$STATE"' EXIT

/bin/chmod 755 "$ROOT_DIR/Tests/fake-launchctl"
: > "$STATE/loaded"
: > "$STATE/fail-bootstrap-once"
export MATVEEV_FAKE_LAUNCHCTL_STATE="$STATE"
export MATVEEV_LAUNCHCTL="$ROOT_DIR/Tests/fake-launchctl"
export MATVEEV_SLEEP=/bin/sleep
SERVICE_LABEL=com.matveev.vpn
SERVICE_PLIST="$STATE/com.matveev.vpn.plist"
. "$ROOT_DIR/Resources/payload/service-lifecycle.sh"

bootout_service
if "$MATVEEV_LAUNCHCTL" print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
  echo "bootout_service returned before launchd removed the old job" >&2
  exit 1
fi
bootstrap_service
"$MATVEEV_LAUNCHCTL" print "system/$SERVICE_LABEL" >/dev/null
[[ ! -e "$STATE/fail-bootstrap-once" ]]
echo "service lifecycle: delayed bootout and transient bootstrap failure passed"
