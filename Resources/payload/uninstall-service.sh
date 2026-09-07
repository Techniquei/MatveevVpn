#!/bin/bash
set -euo pipefail
# Internal service removal, invoked after the app confirmation dialog.
[[ "${1:-}" == "--yes" ]] || exit 2
/usr/bin/osascript <<'APPLESCRIPT'
do shell script "/bin/launchctl bootout system/com.matveev.vpn 2>/dev/null || true; /bin/launchctl disable system/com.matveev.vpn 2>/dev/null || true; /bin/rm -f '/Library/LaunchDaemons/com.matveev.vpn.plist'; /bin/rm -rf '/Library/Application Support/matveevVpn'; /bin/rm -f /tmp/matveev-vpn.log /tmp/matveev-vpn.error.log" with administrator privileges
APPLESCRIPT
