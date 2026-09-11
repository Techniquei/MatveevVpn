#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="$(/usr/bin/mktemp -d /private/tmp/matveev-controller-test.XXXXXX)"
CONTROL="$RUNTIME/control"
CURRENT_DNS="$RUNTIME/current-dns"
DNS_CALL_LOG="$RUNTIME/dns-calls"

/bin/mkdir -p "$RUNTIME/bin" "$RUNTIME/run" "$CONTROL"
/bin/cp "$TEST_DIR/fake-sing-box" "$RUNTIME/bin/sing-box"
/bin/cp "$TEST_DIR/fake-xray" "$RUNTIME/bin/xray"
/bin/cp "$TEST_DIR/fake-networksetup" "$RUNTIME/bin/networksetup"
/bin/cp "$TEST_DIR/../Resources/payload/dns-manager.sh" "$RUNTIME/bin/dns-manager.sh"
/bin/cp "$TEST_DIR/config.json" "$RUNTIME/config.json"
/bin/chmod 755 "$RUNTIME/bin/sing-box" "$RUNTIME/bin/xray" "$RUNTIME/bin/networksetup" "$RUNTIME/bin/dns-manager.sh"
/usr/bin/printf 'on\n' > "$RUNTIME/run/desired-state"
/usr/bin/printf '9.9.9.9\n' > "$CURRENT_DNS"
: > "$DNS_CALL_LOG"
/bin/dd if=/dev/zero of="$RUNTIME/vpn.log" bs=3100000 count=1 2>/dev/null
/bin/dd if=/dev/zero of="$RUNTIME/vpn.error.log" bs=3100000 count=1 2>/dev/null

MATVEEV_BASE_DIR="$RUNTIME" \
MATVEEV_LOG_FILE="$RUNTIME/vpn.log" \
MATVEEV_ERROR_FILE="$RUNTIME/vpn.error.log" \
MATVEEV_NETWORKSETUP="$RUNTIME/bin/networksetup" \
MATVEEV_DEFAULT_INTERFACE="test0" \
MATVEEV_FAKE_DNS="$CURRENT_DNS" \
MATVEEV_FAKE_LOG="$DNS_CALL_LOG" \
  "$TEST_DIR/../Resources/payload/controller.sh" &
CONTROLLER_PID=$!

cleanup() {
  /bin/kill -TERM "$CONTROLLER_PID" 2>/dev/null || true
  wait "$CONTROLLER_PID" 2>/dev/null || true
  /bin/rm -rf "$RUNTIME"
}
trap cleanup EXIT

wait_for_file_value() {
  local file="$1"
  local expected="$2"
  local attempt=0
  while [[ "$attempt" -lt 100 ]]; do
    if [[ -f "$file" && "$(/usr/bin/head -n 1 "$file")" == "$expected" ]]; then
      return 0
    fi
    attempt=$((attempt + 1))
    /bin/sleep 0.1
  done
  echo "Timed out waiting for $file = $expected" >&2
  return 1
}

send_action() {
  local action="$1"
  send_action_expect "$action" "ok"
}

send_action_expect() {
  local action="$1"
  local expected="$2"
  local token="test-$action-$RANDOM"
  /usr/bin/printf '%s %s\n' "$action" "$token" > "$CONTROL/.command-test"
  /bin/mv -f "$CONTROL/.command-test" "$CONTROL/command"
  wait_for_file_value "$CONTROL/response-$token" "$expected"
}

wait_for_file_value "$CONTROL/runtime-status" "running"
[[ "$(/usr/bin/wc -c < "$RUNTIME/vpn.log" | /usr/bin/tr -d '[:space:]')" -le 3000000 ]]
[[ "$(/usr/bin/wc -c < "$RUNTIME/vpn.error.log" | /usr/bin/tr -d '[:space:]')" -le 3000000 ]]
[[ "$(cat "$CURRENT_DNS")" == "198.18.0.2" ]]
send_action off
wait_for_file_value "$CONTROL/runtime-status" "stopped"
[[ "$(cat "$CURRENT_DNS")" == "9.9.9.9" ]]
send_action on
wait_for_file_value "$CONTROL/runtime-status" "running"
[[ "$(cat "$CURRENT_DNS")" == "198.18.0.2" ]]
send_action restart
wait_for_file_value "$CONTROL/runtime-status" "running"
# Selective routing must preserve the physical network service's DNS.
/usr/bin/printf '{"route":{"final":"direct"}}\n' > "$CONTROL/pending-config.json"
send_action reload
wait_for_file_value "$CONTROL/runtime-status" "running"
[[ "$(cat "$CURRENT_DNS")" == "9.9.9.9" ]]
/usr/bin/grep -q 'physical network DNS preserved for Selective mode' "$RUNTIME/vpn.log"
# All Traffic still needs the system DNS override used by existing releases.
/bin/cp "$TEST_DIR/config.json" "$CONTROL/pending-config.json"
/usr/bin/printf '{"valid":true}\n' > "$CONTROL/pending-xray.json"
send_action reload
wait_for_file_value "$CONTROL/runtime-status" "running"
[[ "$(cat "$CURRENT_DNS")" == "198.18.0.2" ]]
[[ -f "$RUNTIME/xray.json" && -f "$RUNTIME/run/xray.pid" ]]
/usr/bin/printf '{"fail_run":true}\n' > "$CONTROL/pending-config.json"
send_action_expect reload error
wait_for_file_value "$CONTROL/runtime-status" "running"
[[ -f "$CONTROL/last-error.log" ]]
/usr/bin/grep -q 'Controller status:' "$CONTROL/last-error.log"
if /usr/bin/grep -q 'fail_run' "$RUNTIME/config.json"; then
  echo "Failed configuration was not rolled back." >&2
  exit 1
fi

echo "controller protocol: ok"
send_action off
/bin/cp "$TEST_DIR/config.json" "$CONTROL/pending-config.json"
send_action reload
wait_for_file_value "$CONTROL/runtime-status" "stopped"
wait_for_file_value "$RUNTIME/run/desired-state" "off"
[[ ! -e "$RUNTIME/xray.json" && ! -e "$RUNTIME/run/xray.pid" ]]
send_action reset
[[ ! -e "$RUNTIME/config.json" ]]
[[ ! -e "$CONTROL/config-sha256" ]]
[[ ! -e "$CONTROL/last-error.log" ]]
send_action_expect on error
wait_for_file_value "$RUNTIME/run/desired-state" "off"
wait_for_file_value "$CONTROL/runtime-status" "error: retry limit reached"
[[ "$(/usr/bin/wc -c < "$RUNTIME/vpn.log" | /usr/bin/tr -d '[:space:]')" -le 3000000 ]]
[[ "$(/usr/bin/wc -c < "$RUNTIME/vpn.error.log" | /usr/bin/tr -d '[:space:]')" -le 3000000 ]]
echo "controller: reload preserves off state; reset removes credentials; retries and logs are bounded"
