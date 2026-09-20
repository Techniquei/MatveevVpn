#!/bin/bash

SERVICE_LABEL="${SERVICE_LABEL:-com.matveev.vpn}"
SERVICE_PLIST="${SERVICE_PLIST:-/Library/LaunchDaemons/com.matveev.vpn.plist}"
LAUNCHCTL_BIN="${MATVEEV_LAUNCHCTL:-/bin/launchctl}"
SLEEP_BIN="${MATVEEV_SLEEP:-/bin/sleep}"

bootout_service() {
  "$LAUNCHCTL_BIN" bootout "system/$SERVICE_LABEL" 2>/dev/null || true
  local attempt
  for attempt in {1..100}; do
    if ! "$LAUNCHCTL_BIN" print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
      return 0
    fi
    "$SLEEP_BIN" 0.1
  done
  /usr/bin/printf 'Timed out waiting for the previous VPN service to terminate.\n' >&2
  return 1
}

bootstrap_service() {
  local attempt output=''
  for attempt in {1..20}; do
    if output="$("$LAUNCHCTL_BIN" bootstrap system "$SERVICE_PLIST" 2>&1)"; then
      return 0
    fi
    if "$LAUNCHCTL_BIN" print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
      return 0
    fi
    "$SLEEP_BIN" 0.25
  done
  /usr/bin/printf 'Could not start the VPN system service after 20 attempts.\n%s\n' "$output" >&2
  return 1
}
