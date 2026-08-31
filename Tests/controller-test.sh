#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="$(/usr/bin/mktemp -d /private/tmp/matveev-controller-test.XXXXXX)"
CONTROL="$RUNTIME/control"

/bin/mkdir -p "$RUNTIME/bin" "$RUNTIME/run" "$CONTROL"
/bin/cp "$TEST_DIR/fake-sing-box" "$RUNTIME/bin/sing-box"
/bin/cp "$TEST_DIR/config.json" "$RUNTIME/config.json"
/bin/chmod 755 "$RUNTIME/bin/sing-box"
/usr/bin/printf 'on\n' > "$RUNTIME/run/desired-state"

MATVEEV_BASE_DIR="$RUNTIME" \
MATVEEV_LOG_FILE="$RUNTIME/vpn.log" \
MATVEEV_ERROR_FILE="$RUNTIME/vpn.error.log" \
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
  local token="test-$action-$RANDOM"
  /usr/bin/printf '%s %s\n' "$action" "$token" > "$CONTROL/.command-test"
  /bin/mv -f "$CONTROL/.command-test" "$CONTROL/command"
  wait_for_file_value "$CONTROL/response-$token" "ok"
}

wait_for_file_value "$CONTROL/runtime-status" "running"
send_action off
wait_for_file_value "$CONTROL/runtime-status" "stopped"
send_action on
wait_for_file_value "$CONTROL/runtime-status" "running"
send_action restart
wait_for_file_value "$CONTROL/runtime-status" "running"
/bin/cp "$TEST_DIR/config.json" "$CONTROL/pending-config.json"
send_action reload
wait_for_file_value "$CONTROL/runtime-status" "running"

echo "controller protocol: ok"
