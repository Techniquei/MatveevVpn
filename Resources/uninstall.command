#!/bin/bash

set -u

echo "The system service and bundled sing-box will be removed."
echo "The ~/VPN settings folder will be kept."
if [[ "${1:-}" != "--yes" ]]; then
  while true; do
    read -r -p "Continue uninstalling? [y/n]: " CONFIRM
    case "$CONFIRM" in
      y|Y) break ;;
      n|N)
        echo "Cancelled."
        read -r -p "Press Enter..." _
        exit 0
        ;;
      *) echo "Enter only y or n." ;;
    esac
  done
fi

/usr/bin/osascript <<'APPLESCRIPT'
do shell script "/bin/launchctl bootout system/com.matveev.vpn 2>/dev/null || true; /bin/launchctl disable system/com.matveev.vpn 2>/dev/null || true; /bin/launchctl bootout system/com.metveev.vpn 2>/dev/null || true; /bin/launchctl disable system/com.metveev.vpn 2>/dev/null || true; /bin/launchctl bootout system/com.local.sing-box-openai 2>/dev/null || true; /bin/launchctl disable system/com.local.sing-box-openai 2>/dev/null || true; /bin/rm -f '/Library/LaunchDaemons/com.matveev.vpn.plist' '/Library/LaunchDaemons/com.metveev.vpn.plist' '/Library/LaunchDaemons/com.local.sing-box-openai.plist'; /bin/rm -rf '/Library/Application Support/matveevVpn' '/Library/Application Support/metveevVpn' '/Library/Application Support/sing-box-openai'; /bin/rm -f /tmp/matveev-vpn.log /tmp/matveev-vpn.error.log /tmp/metveev-vpn.log /tmp/metveev-vpn.error.log /tmp/sing-box-openai.log /tmp/sing-box-openai.error.log" with administrator privileges
APPLESCRIPT

echo "The system service was removed. The ~/VPN folder was kept as a backup."
if [[ "${1:-}" != "--yes" ]]; then
  read -r -p "Press Enter..." _
fi
