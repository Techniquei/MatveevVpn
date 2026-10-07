#!/bin/bash
set -euo pipefail
[[ $# == 5 && "$EUID" == 0 && "$3" =~ ^[0-9]+$ && "$4" =~ ^[0-9]+$ && "$5" =~ ^(on|off)$ ]] || exit 2
PAYLOAD="$1"
CONFIG="$2"
OWNER_UID="$3"
OWNER_GID="$4"
BASE='/Library/Application Support/matveevVpn'
SERVICE_LABEL='com.matveev.vpn'
SERVICE_PLIST='/Library/LaunchDaemons/com.matveev.vpn.plist'
. "$PAYLOAD/service-lifecycle.sh"

APP_BUNDLE="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(os.path.join(sys.argv[1], os.pardir, os.pardir, os.pardir)))' "$PAYLOAD")"
[[ "$APP_BUNDLE" == *.app && -f "$APP_BUNDLE/Contents/Info.plist" && -x "$APP_BUNDLE/Contents/MacOS/matveevVpn" && -f "$CONFIG" ]] || exit 2
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")" == 'com.matveev.vpn' ]] || exit 2
for name in sing-box xray; do
  [[ -x "$PAYLOAD/$name" ]] || exit 2
  /usr/bin/lipo "$PAYLOAD/$name" -verify_arch arm64
  /usr/bin/codesign --verify --strict "$PAYLOAD/$name"
done

BACKUP="$(/usr/bin/mktemp -d /private/tmp/matveev-service-backup.XXXXXX)"
HAD_PREVIOUS=false
BACKUP_READY=false
STOPPED=false
COMPLETED=false
# A native Xray component is a previous installation too, even without the
# legacy controller or config.json. Never delete it as a failed first install.
if [[ -d "$BASE" && ( -x "$BASE/bin/controller.sh" || -x "$BASE/bin/matveev-xray-service" || -f "$SERVICE_PLIST" ) ]]; then
  HAD_PREVIOUS=true
fi

clear_installed_quarantine() {
  /usr/bin/xattr -dr com.apple.quarantine "$BASE/bin" "$SERVICE_PLIST"
}

wait_for_legacy() {
  local desired="${1:-off}" status
  for _ in {1..150}; do
    status="$(/usr/bin/head -n 1 "$BASE/control/runtime-status" 2>/dev/null || true)"
    if [[ "$desired" == off && "$status" == stopped || "$desired" == on && "$status" == running ]]; then return 0; fi
    /bin/sleep 0.1
  done
  return 1
}

wait_for_previous_xray() {
  /usr/bin/python3 - "$BASE/ipc/service.sock" <<'PY_STATUS'
import json, socket, sys, time
end = time.monotonic() + 15
while time.monotonic() < end:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(min(1, end - time.monotonic()))
            sock.connect(sys.argv[1])
            sock.sendall(b'{"version":1,"requestID":"rollback-status","action":"GetStatus","expectedRevision":0}\n')
            with sock.makefile("rb") as stream:
                message = json.loads(stream.readline((1 << 20) + 1))
            if message.get("success"):
                raise SystemExit(0)
    except (OSError, ValueError):
        pass
    time.sleep(min(0.1, max(0, end - time.monotonic())))
raise SystemExit(1)
PY_STATUS
}

cleanup() {
  if [[ "$COMPLETED" != true && "$STOPPED" == true ]]; then
    bootout_service || { /usr/bin/printf 'Could not stop the failed replacement for rollback.\n' >&2; return 1; }
    if [[ "$HAD_PREVIOUS" == true ]]; then
      if [[ "$BACKUP_READY" == true ]]; then
        /bin/rm -rf "$BASE"
        /usr/bin/ditto --noqtn "$BACKUP/base" "$BASE"
        /usr/bin/install -m 644 "$BACKUP/service.plist" "$SERVICE_PLIST"
      fi
      clear_installed_quarantine
      if bootstrap_service; then
        if [[ -x "$BASE/bin/matveev-xray-service" ]]; then
          wait_for_previous_xray || /usr/bin/printf 'Previous Xray service restored but did not answer IPC.\n' >&2
        else
          local desired
          desired="$(/usr/bin/head -n 1 "$BASE/run/desired-state" | /usr/bin/tr -d '[:space:]')"
          wait_for_legacy "$desired" || /usr/bin/printf 'Previous controller restored but did not become ready.\n' >&2
        fi
      else
        /usr/bin/printf 'Could not restart the previous service during rollback.\n' >&2
      fi
    else
      /bin/rm -rf "$BASE"
      /bin/rm -f "$SERVICE_PLIST"
    fi
  fi
  /bin/rm -rf "$BACKUP"
}
trap cleanup EXIT

# install(1) transfers quarantine. Stage copies and remove that attribute before
# executing/bootstrapping them, keeping the downloaded app and other attrs intact.
/usr/bin/install -d -m 755 "$BACKUP/new-bin"
for name in sing-box xray controller.sh dns-manager.sh; do
  /usr/bin/install -m 755 "$PAYLOAD/$name" "$BACKUP/new-bin/$name"
done
/usr/bin/install -m 644 "$PAYLOAD/com.matveev.vpn.plist" "$BACKUP/new.plist"
/usr/bin/xattr -dr com.apple.quarantine "$BACKUP/new-bin" "$BACKUP/new.plist"
/usr/bin/plutil -lint "$BACKUP/new.plist" >/dev/null
for name in sing-box xray; do /usr/bin/codesign --verify --strict "$BACKUP/new-bin/$name"; done
if ! "$BACKUP/new-bin/sing-box" check -c "$CONFIG" >/dev/null 2>&1; then
  /usr/bin/printf 'Installation configuration rejected by sing-box.\n' >&2
  exit 1
fi
if [[ -f "$CONFIG.xray.json" ]] && ! "$BACKUP/new-bin/xray" run -test -c "$CONFIG.xray.json" >/dev/null 2>&1; then
  /usr/bin/printf 'Installation configuration rejected by the optional Xray helper.\n' >&2
  exit 1
fi

# Stop and let the previous engine restore its DNS/routes before taking a full
# snapshot. Sockets are recreated by the daemon instead of copied into backup.
bootout_service
STOPPED=true
if [[ "$HAD_PREVIOUS" == true ]]; then
  /usr/bin/install -d -m 700 "$BACKUP/base"
  shopt -s nullglob dotglob
  for entry in "$BASE"/*; do
    [[ "${entry##*/}" == ipc ]] && continue
    /usr/bin/ditto --noqtn "$entry" "$BACKUP/base/${entry##*/}"
  done
  /bin/cp "$SERVICE_PLIST" "$BACKUP/service.plist"
  BACKUP_READY=true
fi
/bin/rm -rf "$BASE/bin"
/usr/bin/install -d -o root -g wheel -m 755 "$BASE" "$BASE/bin"
/usr/bin/install -d -o root -g wheel -m 700 "$BASE/run"
/usr/bin/install -d -o "$OWNER_UID" -g "$OWNER_GID" -m 700 "$BASE/control"
for name in sing-box xray controller.sh dns-manager.sh; do
  /usr/bin/install -o root -g wheel -m 755 "$BACKUP/new-bin/$name" "$BASE/bin/$name"
done
/usr/bin/install -o root -g wheel -m 600 "$CONFIG" "$BASE/config.json"
if [[ -f "$CONFIG.xray.json" ]]; then
  /usr/bin/install -o root -g wheel -m 600 "$CONFIG.xray.json" "$BASE/xray.json"
else
  /bin/rm -f "$BASE/xray.json"
fi
/usr/bin/install -o root -g wheel -m 644 "$BACKUP/new.plist" "$SERVICE_PLIST"
clear_installed_quarantine
# Readiness must not depend on an Internet connection or corporate filtering.
# The app requests desired-on separately after a successful local installation.
/usr/bin/printf 'off\n' > "$BASE/run/desired-state"
/bin/chmod 600 "$BASE/run/desired-state"
/bin/rm -f "$BASE/control/command" "$BASE/control/pending-config.json" "$BASE/control/pending-xray.json" "$BASE/control/runtime-status"
/usr/bin/printf '28\n' > "$BASE/control/version"
/bin/chmod 644 "$BASE/control/version"
/usr/bin/shasum -a 256 "$BASE/config.json" | /usr/bin/awk '{print $1}' > "$BASE/control/config-sha256"
/bin/chmod 644 "$BASE/control/config-sha256"
/bin/launchctl enable system/com.matveev.vpn
bootstrap_service
wait_for_legacy off || { /usr/bin/printf 'Installed sing-box controller did not report stopped readiness.\n' >&2; exit 1; }
COMPLETED=true
