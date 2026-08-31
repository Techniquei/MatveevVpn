#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$SCRIPT_DIR/.payload"
USER_DIR="$HOME/VPN"
SERVICE_DIR="$USER_DIR/.service"
STAGE_DIR="$(/usr/bin/mktemp -d /private/tmp/matveev-vpn-install.XXXXXX)"
PACKAGE_VERSION="1.0.1"

cleanup() {
  /bin/rm -f "$STAGE_DIR/raw" "$STAGE_DIR/decoded" "$STAGE_DIR/config.json" "$STAGE_DIR/sing-box" "$STAGE_DIR/controller.sh" "$STAGE_DIR/service.plist"
  /bin/rmdir "$STAGE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

decode_subscription() {
  local raw_file="$1"
  local decoded_file="$2"
  if /usr/bin/base64 -D -i "$raw_file" -o "$decoded_file" 2>/dev/null && /usr/bin/grep -q '^vless://' "$decoded_file"; then
    return 0
  fi
  if /usr/bin/grep -q '^vless://' "$raw_file"; then
    /bin/cp "$raw_file" "$decoded_file"
    return 0
  fi
  return 1
}

if [[ "$(/usr/bin/uname -m)" != "arm64" ]]; then
  echo "This build requires an Apple Silicon Mac (arm64)."
  read -r -p "Press Enter..." _
  exit 1
fi

if [[ -e "$USER_DIR" && ! -d "$SERVICE_DIR" ]]; then
  echo "$USER_DIR already exists but does not look like a matveevVpn installation."
  echo "Rename it manually so setup does not touch unrelated files."
  read -r -p "Press Enter..." _
  exit 1
fi

echo "matveevVpn setup"
echo "================="
echo "Enter your own VLESS subscription URL. No third-party keys are bundled."
echo

SUBSCRIPTION_URL=""
SERVER_INDEX=""
SERVER_LABEL=""
read -r -s -p "Paste the subscription URL and press Enter: " SUBSCRIPTION_URL
echo
if [[ -z "$SUBSCRIPTION_URL" ]]; then
  echo "The URL is empty. Setup cancelled."
  read -r -p "Press Enter..." _
  exit 1
fi

echo "Downloading the subscription..."
/usr/bin/curl -fsSL --max-time 45 "$SUBSCRIPTION_URL" -o "$STAGE_DIR/raw"

if ! decode_subscription "$STAGE_DIR/raw" "$STAGE_DIR/decoded"; then
  echo "The subscription does not contain supported VLESS links."
  read -r -p "Press Enter..." _
  exit 1
fi

echo
echo "Available nodes:"
/usr/bin/ruby "$PAYLOAD/tools/list-nodes.rb" "$STAGE_DIR/decoded"
echo
read -r -p "Enter a node number: " SERVER_INDEX
if [[ ! "$SERVER_INDEX" =~ ^[0-9]+$ ]]; then
  echo "Enter a number from the list."
  read -r -p "Press Enter..." _
  exit 1
fi

SERVER_LABEL="$(/usr/bin/ruby "$PAYLOAD/tools/list-nodes.rb" "$STAGE_DIR/decoded" | /usr/bin/awk -F '\t' -v wanted="$SERVER_INDEX" '$1 == wanted {print $2; exit}')"
if [[ -z "$SERVER_LABEL" ]]; then
  echo "That node does not exist."
  read -r -p "Press Enter..." _
  exit 1
fi

/usr/bin/ruby "$PAYLOAD/tools/build-config.rb" "$STAGE_DIR/decoded" "$STAGE_DIR/config.json" "$SERVER_INDEX" "$PAYLOAD/default-rules.json"
"$PAYLOAD/sing-box" check -c "$STAGE_DIR/config.json"

/usr/bin/install -m 755 "$PAYLOAD/sing-box" "$STAGE_DIR/sing-box"
/usr/bin/install -m 755 "$PAYLOAD/controller.sh" "$STAGE_DIR/controller.sh"
/usr/bin/install -m 644 "$PAYLOAD/com.matveev.vpn.plist" "$STAGE_DIR/service.plist"

echo "macOS will ask for an administrator password once to install the TUN controller."
USER_UID="$(/usr/bin/id -u)"
USER_GID="$(/usr/bin/id -g)"
/usr/bin/osascript - "$STAGE_DIR/sing-box" "$STAGE_DIR/config.json" "$STAGE_DIR/controller.sh" "$STAGE_DIR/service.plist" "$USER_UID" "$USER_GID" <<'APPLESCRIPT'
on run argv
  set binarySource to item 1 of argv
  set configSource to item 2 of argv
  set controllerSource to item 3 of argv
  set plistSource to item 4 of argv
  set ownerUid to item 5 of argv
  set ownerGid to item 6 of argv
  set installCommand to "(/bin/launchctl bootout system/com.matveev.vpn 2>/dev/null || true) && " & ¬
    "(/bin/launchctl bootout system/com.metveev.vpn 2>/dev/null || true) && " & ¬
    "(/bin/launchctl disable system/com.metveev.vpn 2>/dev/null || true) && " & ¬
    "(/bin/launchctl bootout system/com.local.sing-box-openai 2>/dev/null || true) && " & ¬
    "(/bin/launchctl disable system/com.local.sing-box-openai 2>/dev/null || true) && " & ¬
    "/bin/rm -f '/Library/LaunchDaemons/com.metveev.vpn.plist' '/Library/LaunchDaemons/com.local.sing-box-openai.plist' && " & ¬
    "/bin/rm -rf '/Library/Application Support/metveevVpn' '/Library/Application Support/sing-box-openai' && " & ¬
    "/bin/rm -f /tmp/metveev-vpn.log /tmp/metveev-vpn.error.log /tmp/sing-box-openai.log /tmp/sing-box-openai.error.log && " & ¬
    "/usr/bin/install -d -o root -g wheel -m 755 '/Library/Application Support/matveevVpn/bin' '/Library/Application Support/matveevVpn/run' && " & ¬
    "/usr/bin/install -d -o " & ownerUid & " -g " & ownerGid & " -m 700 '/Library/Application Support/matveevVpn/control' && " & ¬
    "/usr/bin/install -o root -g wheel -m 755 " & quoted form of binarySource & " '/Library/Application Support/matveevVpn/bin/sing-box' && " & ¬
    "/usr/bin/install -o root -g wheel -m 755 " & quoted form of controllerSource & " '/Library/Application Support/matveevVpn/bin/controller.sh' && " & ¬
    "/usr/bin/install -o root -g wheel -m 600 " & quoted form of configSource & " '/Library/Application Support/matveevVpn/config.json' && " & ¬
    "/usr/bin/install -o root -g wheel -m 644 " & quoted form of plistSource & " '/Library/LaunchDaemons/com.matveev.vpn.plist' && " & ¬
    "/usr/bin/printf 'on\\n' > '/Library/Application Support/matveevVpn/run/desired-state' && " & ¬
    "/bin/chmod 600 '/Library/Application Support/matveevVpn/run/desired-state' && " & ¬
    "/bin/launchctl enable system/com.matveev.vpn && " & ¬
    "/bin/launchctl bootstrap system '/Library/LaunchDaemons/com.matveev.vpn.plist' && " & ¬
    "/bin/launchctl kickstart -k system/com.matveev.vpn"
  do shell script installCommand with administrator privileges
end run
APPLESCRIPT

SERVICE_READY=false
for _ in {1..60}; do
  if /bin/launchctl print system/com.matveev.vpn 2>/dev/null | /usr/bin/grep -q 'state = running' && \
     [[ "$(/usr/bin/head -n 1 '/Library/Application Support/matveevVpn/control/runtime-status' 2>/dev/null || true)" == "running" ]]; then
    SERVICE_READY=true
    break
  fi
  /bin/sleep 0.5
done
if [[ "$SERVICE_READY" != true ]]; then
  echo "The service did not start. Check /tmp/matveev-vpn.error.log"
  read -r -p "Press Enter..." _
  exit 1
fi

if [[ -d "$SERVICE_DIR" ]]; then
  BACKUP_DIR="$HOME/VPN.backup-$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mv "$USER_DIR" "$BACKUP_DIR"
  echo "Previous settings moved to $BACKUP_DIR"
fi

echo "Installing matveevVpn data in $USER_DIR ..."
/bin/mkdir -p "$SERVICE_DIR/private" "$SERVICE_DIR/tools"
/usr/bin/install -m 700 "$PAYLOAD/vpn-control.sh.template" "$SERVICE_DIR/vpn-control.sh"
/usr/bin/install -m 600 "$PAYLOAD/README.md.template" "$USER_DIR/README.md"
/usr/bin/install -m 600 "$PAYLOAD/default-rules.json" "$USER_DIR/routing-rules.json"
/usr/bin/install -m 700 "$PAYLOAD/tools/build-config.rb" "$SERVICE_DIR/tools/build-config.rb"
/usr/bin/install -m 700 "$PAYLOAD/tools/list-nodes.rb" "$SERVICE_DIR/tools/list-nodes.rb"
/usr/bin/install -m 600 "$STAGE_DIR/config.json" "$SERVICE_DIR/config.json"
/usr/bin/install -m 600 "$STAGE_DIR/raw" "$SERVICE_DIR/private/subscription.raw"
/usr/bin/install -m 600 "$STAGE_DIR/decoded" "$SERVICE_DIR/private/subscription.decoded"
if [[ -n "$SUBSCRIPTION_URL" ]]; then
  /usr/bin/printf '%s\n' "$SUBSCRIPTION_URL" > "$SERVICE_DIR/private/subscription-url.txt"
fi
/usr/bin/printf '%s\n' "$SERVER_INDEX" > "$SERVICE_DIR/current-server.txt"
/usr/bin/printf '%s\n' "$PACKAGE_VERSION" > "$SERVICE_DIR/package-version.txt"
/bin/chmod 700 "$USER_DIR" "$SERVICE_DIR" "$SERVICE_DIR/private" "$SERVICE_DIR/tools"
/bin/chmod 600 "$SERVICE_DIR/current-server.txt" "$SERVICE_DIR/package-version.txt"
if [[ -f "$SERVICE_DIR/private/subscription-url.txt" ]]; then
  /bin/chmod 600 "$SERVICE_DIR/private/subscription-url.txt"
fi

DIRECT_IP="$(/usr/bin/curl -4fsS --max-time 15 https://checkip.amazonaws.com 2>/dev/null | /usr/bin/tr -d '[:space:]' || true)"
ROUTED_IP="$(/usr/bin/curl -4fsS --max-time 20 https://chatgpt.com/cdn-cgi/trace 2>/dev/null | /usr/bin/awk -F= '$1 == "ip" {print $2; exit}' | /usr/bin/tr -d '[:space:]' || true)"

echo
echo "Setup complete. Selected node: $SERVER_LABEL"
echo "Direct IP: ${DIRECT_IP:-unavailable}"
echo "Routed IP: ${ROUTED_IP:-unavailable}"
if [[ -n "$DIRECT_IP" && -n "$ROUTED_IP" && "$DIRECT_IP" != "$ROUTED_IP" ]]; then
  echo "Selective routing is working."
else
  echo "The IP check was inconclusive. Open matveevVpn and refresh the status."
fi
read -r -p "Press Enter..." _
