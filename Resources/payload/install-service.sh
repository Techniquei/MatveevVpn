#!/bin/bash
set -euo pipefail
[[ $# == 5 && "$EUID" == 0 && "$3" =~ ^[0-9]+$ && "$4" =~ ^[0-9]+$ && "$5" =~ ^(on|off)$ ]] || exit 2
PAYLOAD="$1"
CONFIG="$2"
OWNER_UID="$3"
OWNER_GID="$4"
DESIRED="$5"
BASE='/Library/Application Support/matveevVpn'
"$PAYLOAD/sing-box" check -c "$CONFIG" >/dev/null 2>&1
if [[ -f "$CONFIG.xray.json" ]]; then
  "$PAYLOAD/xray" run -test -c "$CONFIG.xray.json" >/dev/null 2>&1
fi
BACKUP="$(/usr/bin/mktemp -d /private/tmp/matveev-service-backup.XXXXXX)"
HAD_PREVIOUS=false
if [[ -f "$BASE/config.json" && -x "$BASE/bin/controller.sh" ]]; then
  HAD_PREVIOUS=true
  /usr/bin/ditto "$BASE/bin" "$BACKUP/bin"
  /bin/cp "$BASE/config.json" "$BACKUP/config.json"
  if [[ -f "$BASE/xray.json" ]]; then /bin/cp "$BASE/xray.json" "$BACKUP/xray.json"; fi
  /bin/cp /Library/LaunchDaemons/com.matveev.vpn.plist "$BACKUP/service.plist"
  /bin/cp "$BASE/run/desired-state" "$BACKUP/desired-state" 2>/dev/null || /usr/bin/printf 'off\n' > "$BACKUP/desired-state"
  if [[ -f "$BASE/control/version" ]]; then /bin/cp "$BASE/control/version" "$BACKUP/version"; fi
fi
COMPLETED=false
cleanup() {
  if [[ "$COMPLETED" != true && "$HAD_PREVIOUS" == true ]]; then
    /bin/launchctl bootout system/com.matveev.vpn 2>/dev/null || true
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
    /usr/bin/shasum -a 256 "$BASE/config.json" | /usr/bin/awk '{print $1}' > "$BASE/control/config-sha256"
    /bin/chmod 644 "$BASE/control/config-sha256"
    /bin/launchctl bootstrap system /Library/LaunchDaemons/com.matveev.vpn.plist || true
  fi
  /bin/rm -rf "$BACKUP"
}
trap cleanup EXIT
/bin/launchctl bootout system/com.matveev.vpn 2>/dev/null || true
/usr/bin/install -d -o root -g wheel -m 755 "$BASE/bin"
/usr/bin/install -d -o root -g wheel -m 700 "$BASE/run"
/usr/bin/install -d -o "$OWNER_UID" -g "$OWNER_GID" -m 700 "$BASE/control"
/usr/bin/install -o root -g wheel -m 755 "$PAYLOAD/sing-box" "$BASE/bin/sing-box"
/usr/bin/install -o root -g wheel -m 755 "$PAYLOAD/xray" "$BASE/bin/xray"
/usr/bin/install -o root -g wheel -m 755 "$PAYLOAD/controller.sh" "$BASE/bin/controller.sh"
/usr/bin/install -o root -g wheel -m 755 "$PAYLOAD/dns-manager.sh" "$BASE/bin/dns-manager.sh"
/usr/bin/install -o root -g wheel -m 600 "$CONFIG" "$BASE/config.json"
if [[ -f "$CONFIG.xray.json" ]]; then
  /usr/bin/install -o root -g wheel -m 600 "$CONFIG.xray.json" "$BASE/xray.json"
else
  /bin/rm -f "$BASE/xray.json"
fi
/usr/bin/install -o root -g wheel -m 644 "$PAYLOAD/com.matveev.vpn.plist" /Library/LaunchDaemons/com.matveev.vpn.plist
/usr/bin/printf '%s\n' "$DESIRED" > "$BASE/run/desired-state"
/bin/chmod 600 "$BASE/run/desired-state"
/bin/rm -f "$BASE/control/command" "$BASE/control/pending-config.json" "$BASE/control/pending-xray.json" "$BASE/control/runtime-status"
/usr/bin/printf '9\n' > "$BASE/control/version"
/bin/chmod 644 "$BASE/control/version"
/bin/launchctl enable system/com.matveev.vpn
/bin/launchctl bootstrap system /Library/LaunchDaemons/com.matveev.vpn.plist
for _ in {1..150}; do
  ACTUAL="$(/usr/bin/head -n 1 "$BASE/control/runtime-status" 2>/dev/null || true)"
  if [[ "$DESIRED" == on && "$ACTUAL" == running || "$DESIRED" == off && "$ACTUAL" == stopped ]]; then
    COMPLETED=true
    exit 0
  fi
  /bin/sleep 0.1
done
exit 1
