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

# Validate the source before stopping a working installation. Never clear
# quarantine on the downloaded app: only the administrator-installed copies.
APP_BUNDLE="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(os.path.join(sys.argv[1], os.pardir, os.pardir, os.pardir)))' "$PAYLOAD")"
[[ "$APP_BUNDLE" == *.app && -f "$APP_BUNDLE/Contents/Info.plist" && -x "$APP_BUNDLE/Contents/MacOS/matveevVpn" && -f "$CONFIG" ]] || exit 2
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")" == "com.matveev.vpn" ]] || exit 2
for name in matveev-xray-service matveev-xray-worker; do
  [[ -x "$PAYLOAD/$name" ]] || exit 2
  /usr/bin/lipo "$PAYLOAD/$name" -verify_arch arm64
  /usr/bin/codesign --verify --strict "$PAYLOAD/$name"
done

BACKUP="$(/usr/bin/mktemp -d /private/tmp/matveev-service-backup.XXXXXX)"
HAD_PREVIOUS=false
BACKUP_READY=false
STOPPED=false
COMPLETED=false
if [[ -x "$BASE/bin/matveev-xray-service" || -x "$BASE/bin/controller.sh" ]]; then
  HAD_PREVIOUS=true
fi

clear_installed_quarantine() {
  # install(1) preserves quarantine even with COPYFILE_DISABLE=1. Old files
  # and a restored plist can carry it too. Preserve all other attributes.
  /usr/bin/xattr -dr com.apple.quarantine "$BASE/bin" "$SERVICE_PLIST"
}

wait_for_service() {
  /usr/bin/python3 - "$BASE/ipc/service.sock" <<'PY_STATUS'
import json, socket, sys, time
end = time.monotonic() + 15
while time.monotonic() < end:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(min(1, end - time.monotonic()))
            sock.connect(sys.argv[1])
            sock.sendall(b'{"version":1,"requestID":"install-status","action":"GetStatus","expectedRevision":0}\n')
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
    bootout_service || { /usr/bin/printf 'Could not stop the failed installation for rollback.\n' >&2; return 1; }
    if [[ "$HAD_PREVIOUS" == true ]]; then
      if [[ "$BACKUP_READY" == true ]]; then
        /bin/rm -rf "$BASE"
        /usr/bin/ditto --noqtn "$BACKUP/base" "$BASE"
        /usr/bin/install -m 644 "$BACKUP/service.plist" "$SERVICE_PLIST"
      fi
      clear_installed_quarantine
      if bootstrap_service; then
        if [[ -x "$BASE/bin/matveev-xray-service" ]]; then
          wait_for_service || /usr/bin/printf 'Previous Xray service was restored but did not become ready.\n' >&2
        else
          local desired status ready=false
          desired="$(/usr/bin/head -n 1 "$BASE/run/desired-state" | /usr/bin/tr -d '[:space:]')"
          for _ in {1..150}; do
            status="$(/usr/bin/head -n 1 "$BASE/control/runtime-status" 2>/dev/null || true)"
            if [[ "$desired" == on && "$status" == running || "$desired" == off && "$status" == stopped ]]; then
              ready=true; break
            fi
            /bin/sleep 0.1
          done
          [[ "$ready" == true ]] || /usr/bin/printf 'Previous controller was restored but did not become ready.\n' >&2
        fi
      else
        /usr/bin/printf 'Could not restart the previous VPN service during rollback.\n' >&2
      fi
    else
      # A failed first installation must not look installed on the next launch.
      /bin/rm -rf "$BASE"
      /bin/rm -f "$SERVICE_PLIST"
    fi
  fi
  /bin/rm -rf "$BACKUP"
}
trap cleanup EXIT

# Stage and verify the exact installed copies before touching the old daemon.
/usr/bin/install -d -m 755 "$BACKUP/new-bin"
for name in matveev-xray-service matveev-xray-worker; do
  /usr/bin/install -m 755 "$PAYLOAD/$name" "$BACKUP/new-bin/$name"
done
/usr/bin/install -m 644 "$PAYLOAD/com.matveev.vpn.plist" "$BACKUP/new.plist"
/usr/bin/xattr -dr com.apple.quarantine "$BACKUP/new-bin" "$BACKUP/new.plist"
/usr/bin/plutil -lint "$BACKUP/new.plist" >/dev/null
for name in matveev-xray-service matveev-xray-worker; do
  /usr/bin/codesign --verify --strict "$BACKUP/new-bin/$name"
done

# SIGTERM restores the previous daemon's DNS/routes before snapshotting state.
bootout_service
STOPPED=true
if [[ "$HAD_PREVIOUS" == true ]]; then
  /usr/bin/install -d -m 700 "$BACKUP/base"
  shopt -s nullglob
  for entry in "$BASE"/*; do
    # Sockets are recreated, never backed up or restored.
    [[ "${entry##*/}" == ipc ]] && continue
    /usr/bin/ditto --noqtn "$entry" "$BACKUP/base/${entry##*/}"
  done
  /bin/cp "$SERVICE_PLIST" "$BACKUP/service.plist"
  BACKUP_READY=true
fi
# The complete old bin directory is backed up. Do not leave legacy engines or
# DNS scripts beside the replacement; uninstall must use the current service.
/bin/rm -rf "$BASE/bin"
/usr/bin/install -d -o root -g wheel -m 755 "$BASE" "$BASE/bin"
/usr/bin/install -d -o root -g wheel -m 700 "$BASE/run" "$BASE/rules"
/usr/bin/install -d -o "$OWNER_UID" -g "$OWNER_GID" -m 700 "$BASE/control"
for name in matveev-xray-service matveev-xray-worker; do
  /usr/bin/install -o root -g wheel -m 755 "$BACKUP/new-bin/$name" "$BASE/bin/$name"
done
if [[ -f "$PAYLOAD/rules/hagezi-pro-mini.txt" ]]; then
  /usr/bin/install -o root -g wheel -m 644 "$PAYLOAD/rules/hagezi-pro-mini.txt" "$BASE/rules/hagezi-pro-mini.txt"
fi
/usr/bin/printf '%s %s\n' "$OWNER_UID" "$OWNER_GID" > "$BASE/owner-uid"
/bin/chmod 644 "$BASE/owner-uid"
/usr/bin/install -o root -g wheel -m 644 "$BACKUP/new.plist" "$SERVICE_PLIST"
clear_installed_quarantine
/bin/rm -f "$BASE/control/command" "$BASE/control/pending-config.json" "$BASE/control/pending-xray.json" "$BASE/control/runtime-status"
/usr/bin/printf '26\n' > "$BASE/control/version"
/bin/chmod 644 "$BASE/control/version"
/usr/bin/printf '%s\n' "$APP_BUNDLE" > "$BASE/app-bundle"
/bin/chmod 644 "$BASE/app-bundle"

# Even a repaired Xray installation boots stopped. Its entire stopped state was
# backed up above; rollback restores the previous desired state and snapshots.
if [[ -f "$BASE/state/accepted.json" ]]; then
  /usr/bin/python3 - "$BASE/state/accepted.json" <<'PY_STOP'
import json, os, sys, tempfile
path = sys.argv[1]
with open(path) as stream:
    state = json.load(stream)
state["desiredOn"] = False
fd, stage = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".install-")
try:
    with os.fdopen(fd, "w") as stream:
        json.dump(state, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(stage, path)
finally:
    if os.path.exists(stage):
        os.unlink(stage)
PY_STOP
fi
/bin/launchctl enable system/com.matveev.vpn
bootstrap_service
wait_for_service || { /usr/bin/printf 'Installed VPN service did not answer GetStatus.\n' >&2; exit 1; }

# Local readiness alone is insufficient: accept the supplied intent while off.
# Internet connectivity is a separate operation requested by the Swift caller.
/usr/bin/python3 - "$BASE/ipc/service.sock" "$CONFIG" <<'PY_APPLY'
import json, socket, sys, uuid

def call(action, revision=0, payload=None):
    message = {"version": 1, "requestID": str(uuid.uuid4()), "action": action, "expectedRevision": revision}
    if payload is not None:
        message["payload"] = payload
    data = json.dumps(message).encode() + b"\n"
    if len(data) > (1 << 20):
        raise SystemExit("Installation configuration exceeds the IPC limit.")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(16)
        sock.connect(sys.argv[1])
        sock.sendall(data)
        with sock.makefile("rb") as stream:
            reply = json.loads(stream.readline((1 << 20) + 1))
    if not reply.get("success"):
        raise SystemExit("VPN service rejected the installation configuration.")
    return reply["status"]

with open(sys.argv[2]) as stream:
    intent = json.load(stream)
status = call("GetStatus")
status = call("Apply", status["acceptedRevision"], intent)
status = call("SetDesiredOn", status["acceptedRevision"], {"desiredOn": False})
if status["desiredOn"] or status["runtimeState"] != "off":
    raise SystemExit("Installed VPN service did not remain stopped.")
PY_APPLY
/usr/bin/install -o root -g wheel -m 600 "$CONFIG" "$BASE/config.json"
/usr/bin/shasum -a 256 "$BASE/config.json" | /usr/bin/awk '{print $1}' > "$BASE/control/config-sha256"
/bin/chmod 644 "$BASE/control/config-sha256"
COMPLETED=true
