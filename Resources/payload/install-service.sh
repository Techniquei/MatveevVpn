#!/bin/bash
set -euo pipefail
[[ $# == 5 && "$EUID" == 0 && "$3" =~ ^[0-9]+$ && "$4" =~ ^[0-9]+$ && "$5" =~ ^(on|off)$ ]] || exit 2
PAYLOAD="$1"
CONFIG="$2"
OWNER_UID="$3"
OWNER_GID="$4"
DESIRED="$5"
BASE='/Library/Application Support/matveevVpn'
SERVICE_LABEL='com.matveev.vpn'
SERVICE_PLIST='/Library/LaunchDaemons/com.matveev.vpn.plist'
. "$PAYLOAD/service-lifecycle.sh"

[[ -x "$PAYLOAD/matveev-xray-service" && -x "$PAYLOAD/matveev-xray-worker" ]] || exit 2
BACKUP="$(/usr/bin/mktemp -d /private/tmp/matveev-service-backup.XXXXXX)"
HAD_PREVIOUS=false
if [[ -x "$BASE/bin/matveev-xray-service" || ( -f "$BASE/config.json" && -x "$BASE/bin/controller.sh" ) ]]; then
  HAD_PREVIOUS=true
  /usr/bin/ditto "$BASE/bin" "$BACKUP/bin"
  /bin/cp "$BASE/config.json" "$BACKUP/config.json"
  if [[ -f "$BASE/xray.json" ]]; then /bin/cp "$BASE/xray.json" "$BACKUP/xray.json"; fi
  /bin/cp /Library/LaunchDaemons/com.matveev.vpn.plist "$BACKUP/service.plist"
  /bin/cp "$BASE/run/desired-state" "$BACKUP/desired-state" 2>/dev/null || /usr/bin/printf 'off\n' > "$BACKUP/desired-state"
  if [[ -f "$BASE/control/version" ]]; then /bin/cp "$BASE/control/version" "$BACKUP/version"; fi
  if [[ -f "$BASE/app-bundle" ]]; then /bin/cp "$BASE/app-bundle" "$BACKUP/app-bundle"; fi
fi
COMPLETED=false
cleanup() {
  if [[ "$COMPLETED" != true && "$HAD_PREVIOUS" == true ]]; then
    bootout_service || true
    /usr/bin/ditto "$BACKUP/bin" "$BASE/bin"
    /usr/bin/install -m 600 "$BACKUP/config.json" "$BASE/config.json"
    if [[ -f "$BACKUP/xray.json" ]]; then
      /usr/bin/install -m 600 "$BACKUP/xray.json" "$BASE/xray.json"
    else
      /bin/rm -f "$BASE/xray.json"
    fi
    /usr/bin/install -m 600 "$BACKUP/desired-state" "$BASE/run/desired-state"
    /usr/bin/install -m 644 "$BACKUP/service.plist" /Library/LaunchDaemons/com.matveev.vpn.plist
    if [[ -f "$BACKUP/version" ]]; then
      /usr/bin/install -m 644 "$BACKUP/version" "$BASE/control/version"
    else
      /bin/rm -f "$BASE/control/version"
    fi
    if [[ -f "$BACKUP/app-bundle" ]]; then
      /usr/bin/install -m 644 "$BACKUP/app-bundle" "$BASE/app-bundle"
    else
      /bin/rm -f "$BASE/app-bundle"
    fi
    /usr/bin/shasum -a 256 "$BASE/config.json" | /usr/bin/awk '{print $1}' > "$BASE/control/config-sha256"
    /bin/chmod 644 "$BASE/control/config-sha256"
    if bootstrap_service; then
      ROLLBACK_DESIRED="$(/usr/bin/head -n 1 "$BACKUP/desired-state" | /usr/bin/tr -d '[:space:]')"
      ROLLBACK_READY=false
      for _ in {1..150}; do
        ROLLBACK_STATUS="$(/usr/bin/head -n 1 "$BASE/control/runtime-status" 2>/dev/null || true)"
        if [[ "$ROLLBACK_DESIRED" == on && "$ROLLBACK_STATUS" == running || "$ROLLBACK_DESIRED" == off && "$ROLLBACK_STATUS" == stopped ]]; then
          ROLLBACK_READY=true
          break
        fi
        /bin/sleep 0.1
      done
      if [[ "$ROLLBACK_READY" != true ]]; then
        /usr/bin/printf 'Previous VPN service was restored but did not become ready before the rollback deadline.\n' >&2
      fi
    else
      /usr/bin/printf 'Could not restart the previous VPN service during rollback.\n' >&2
    fi
  elif [[ "$COMPLETED" != true ]]; then
    # A failed first installation must not look installed on the next launch.
    bootout_service || true
    /bin/rm -rf "$BASE"
    /bin/rm -f "$SERVICE_PLIST"
  fi
  /bin/rm -rf "$BACKUP"
}
trap cleanup EXIT
# Stop the previous daemon first. Its SIGTERM handler restores DNS and routes it owns.
bootout_service
/usr/bin/install -d -o root -g wheel -m 755 "$BASE/bin"
/usr/bin/install -d -o root -g wheel -m 700 "$BASE/run" "$BASE/rules"
/usr/bin/install -d -o "$OWNER_UID" -g "$OWNER_GID" -m 700 "$BASE/control"
/usr/bin/install -o root -g wheel -m 755 "$PAYLOAD/matveev-xray-service" "$BASE/bin/matveev-xray-service"
/usr/bin/install -o root -g wheel -m 755 "$PAYLOAD/matveev-xray-worker" "$BASE/bin/matveev-xray-worker"
if [[ -f "$PAYLOAD/rules/hagezi-pro-mini.txt" ]]; then
  /usr/bin/install -o root -g wheel -m 644 "$PAYLOAD/rules/hagezi-pro-mini.txt" "$BASE/rules/hagezi-pro-mini.txt"
fi
/usr/bin/printf '%s %s\n' "$OWNER_UID" "$OWNER_GID" > "$BASE/owner-uid"
/bin/chmod 644 "$BASE/owner-uid"
/usr/bin/install -o root -g wheel -m 644 "$PAYLOAD/com.matveev.vpn.plist" "$SERVICE_PLIST"
/bin/rm -f "$BASE/control/command" "$BASE/control/pending-config.json" "$BASE/control/pending-xray.json" "$BASE/control/runtime-status"
/usr/bin/printf '24\n' > "$BASE/control/version"
/bin/chmod 644 "$BASE/control/version"
# The launchd service outlives the app. Remember the bundle that installed it
# so the tunnel stops when that bundle is removed. Quitting the app leaves it in place.
APP_BUNDLE="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(os.path.join(sys.argv[1], os.pardir, os.pardir, os.pardir)))' "$PAYLOAD")"
[[ "$APP_BUNDLE" == *.app && -f "$APP_BUNDLE/Contents/Info.plist" && -x "$APP_BUNDLE/Contents/MacOS/matveevVpn" ]] || exit 2
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")" == "com.matveev.vpn" ]] || exit 2
/usr/bin/printf '%s\n' "$APP_BUNDLE" > "$BASE/app-bundle"
/bin/chmod 644 "$BASE/app-bundle"
/bin/launchctl enable system/com.matveev.vpn
bootstrap_service
for _ in {1..150}; do
  if [[ -S "$BASE/ipc/service.sock" ]] && /usr/bin/python3 - "$BASE/ipc/service.sock" <<'PY'
import json, socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(2)
sock.connect(sys.argv[1])
sock.sendall(json.dumps({"version": 1, "requestID": "install-status", "action": "GetStatus", "expectedRevision": 0}).encode() + b"\n")
data = b""
while b"\n" not in data:
    chunk = sock.recv(4096)
    if not chunk:
        break
    data += chunk
message = json.loads(data.split(b"\n", 1)[0])
raise SystemExit(0 if message.get("success") else 1)
PY
  then
    COMPLETED=true
    exit 0
  fi
  /bin/sleep 0.1
done
exit 1
