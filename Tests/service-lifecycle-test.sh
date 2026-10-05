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

# Exercise the installer's first-install cleanup against the same fake launchctl.
export MATVEEV_INSTALL_TEST_BASE="$STATE/service"
export MATVEEV_INSTALL_TEST_PLIST="$STATE/service.plist"
/bin/mkdir -p "$STATE/payload"
/bin/cp "$ROOT_DIR/Tests/fake-sing-box" "$STATE/payload/matveev-xray-service"
/bin/cp "$ROOT_DIR/Tests/fake-sing-box" "$STATE/payload/matveev-xray-worker"
/bin/cp "$ROOT_DIR/Resources/payload/service-lifecycle.sh" "$STATE/payload/service-lifecycle.sh"
/bin/chmod 755 "$STATE/payload/matveev-xray-service" "$STATE/payload/matveev-xray-worker"
/usr/bin/printf '{}\n' > "$STATE/config.json"
/usr/bin/ruby - "$ROOT_DIR/Resources/payload/install-service.sh" "$STATE/installer-cleanup.sh" <<'RUBY'
source = File.read(ARGV[0]).split("trap cleanup EXIT\n").first
abort 'installer cleanup boundary was not found' unless source.include?('cleanup() {')
source = source.sub(' && "$EUID" == 0', '')
source = source.gsub('/Library/Application Support/matveevVpn', ENV.fetch('MATVEEV_INSTALL_TEST_BASE'))
source = source.gsub('/Library/LaunchDaemons/com.matveev.vpn.plist', ENV.fetch('MATVEEV_INSTALL_TEST_PLIST'))
abort 'installer fixture retained a system path' if source.include?('/Library/')
File.write(ARGV[1], source)
RUBY
. "$STATE/installer-cleanup.sh" "$STATE/payload" "$STATE/config.json" "$(id -u)" "$(id -g)" off
/bin/mkdir -p "$BASE/bin" "$BASE/control"
: > "$BASE/bin/controller.sh"
: > "$BASE/config.json"
: > "$BASE/control/version"
: > "$SERVICE_PLIST"
: > "$STATE/loaded"
cleanup
[[ ! -e "$BASE" && ! -e "$SERVICE_PLIST" && ! -e "$BACKUP" && ! -e "$STATE/loaded" ]]
echo "first installation: failure removes the partial component and permits retry"
