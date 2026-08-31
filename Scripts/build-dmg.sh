#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.0.1"
BUILD_NUMBER="101"
SING_BOX_VERSION="1.13.19"
SING_BOX_ARCHIVE_SHA256="23bf191906f2dfc9f00e9f0092f274f3426ba9377327e903ff94e636b64d0997"
DIST_DIR="${1:-$ROOT_DIR/dist}"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/matveev-vpn-build.XXXXXX)"
APP="$WORK_DIR/matveevVpn.app"
DMG_MOUNT="$WORK_DIR/mount"
RW_DMG="$WORK_DIR/matveevVpn-rw.dmg"
OUTPUT_DMG="$DIST_DIR/matveevVpn-$VERSION-arm64.dmg"
DEVICE=""

cleanup() {
  if [[ -n "$DEVICE" ]]; then
    /usr/bin/hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$DIST_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources/.payload/tools"

echo "Compiling matveevVpn $VERSION..."
/usr/bin/xcrun --sdk macosx swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macos13.0 \
  "$ROOT_DIR/Sources/matveevVpn.swift" \
  -o "$APP/Contents/MacOS/matveevVpn"

INFO_PLIST="$APP/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleDevelopmentRegion -string en "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleDisplayName -string matveevVpn "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleExecutable -string matveevVpn "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleIdentifier -string com.matveev.vpn "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleName -string matveevVpn "$INFO_PLIST"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$VERSION" "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$INFO_PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 13.0 "$INFO_PLIST"
/usr/bin/plutil -insert LSUIElement -bool false "$INFO_PLIST"
/usr/bin/plutil -insert NSHighResolutionCapable -bool true "$INFO_PLIST"

/usr/bin/install -m 644 "$ROOT_DIR/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/install -m 755 "$ROOT_DIR/Resources/setup.command" "$APP/Contents/Resources/setup.command"
/usr/bin/install -m 755 "$ROOT_DIR/Resources/uninstall.command" "$APP/Contents/Resources/uninstall.command"
/usr/bin/install -m 644 "$ROOT_DIR/Resources/README.txt" "$APP/Contents/Resources/README.txt"
/usr/bin/install -m 644 "$ROOT_DIR/Resources/payload/README.md.template" "$APP/Contents/Resources/.payload/README.md.template"
/usr/bin/install -m 755 "$ROOT_DIR/Resources/payload/vpn-control.sh.template" "$APP/Contents/Resources/.payload/vpn-control.sh.template"
/usr/bin/install -m 644 "$ROOT_DIR/Resources/payload/com.matveev.vpn.plist" "$APP/Contents/Resources/.payload/com.matveev.vpn.plist"
/usr/bin/install -m 755 "$ROOT_DIR/Resources/payload/controller.sh" "$APP/Contents/Resources/.payload/controller.sh"
/usr/bin/install -m 644 "$ROOT_DIR/Resources/payload/default-rules.json" "$APP/Contents/Resources/.payload/default-rules.json"
/usr/bin/install -m 755 "$ROOT_DIR/Resources/payload/tools/build-config.rb" "$APP/Contents/Resources/.payload/tools/build-config.rb"
/usr/bin/install -m 755 "$ROOT_DIR/Resources/payload/tools/list-nodes.rb" "$APP/Contents/Resources/.payload/tools/list-nodes.rb"

if [[ -n "${MATVEEV_SING_BOX_BINARY:-}" ]]; then
  echo "Using local sing-box binary..."
  /usr/bin/install -m 755 "$MATVEEV_SING_BOX_BINARY" "$APP/Contents/Resources/.payload/sing-box"
else
  ARCHIVE="$WORK_DIR/sing-box.tar.gz"
  URL="https://github.com/SagerNet/sing-box/releases/download/v$SING_BOX_VERSION/sing-box-$SING_BOX_VERSION-darwin-arm64.tar.gz"
  echo "Downloading sing-box $SING_BOX_VERSION..."
  /usr/bin/curl -fL --retry 3 --connect-timeout 15 --max-time 180 "$URL" -o "$ARCHIVE"
  ACTUAL_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
  if [[ "$ACTUAL_SHA" != "$SING_BOX_ARCHIVE_SHA256" ]]; then
    echo "sing-box checksum mismatch" >&2
    exit 1
  fi
  /usr/bin/tar -xzf "$ARCHIVE" -C "$WORK_DIR"
  /usr/bin/install -m 755 \
    "$WORK_DIR/sing-box-$SING_BOX_VERSION-darwin-arm64/sing-box" \
    "$APP/Contents/Resources/.payload/sing-box"
fi

/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo "Creating DMG..."
mkdir -p "$DMG_MOUNT"
/usr/bin/hdiutil create -size 96m -fs HFS+ -volname matveevVpn -ov "$RW_DMG" >/dev/null
ATTACH_OUTPUT="$(/usr/bin/hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$DMG_MOUNT" "$RW_DMG")"
DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | /usr/bin/awk '/Apple_HFS/ {print $1; exit}')"
/usr/bin/ditto --noextattr --noqtn "$APP" "$DMG_MOUNT/matveevVpn.app"
/bin/ln -s /Applications "$DMG_MOUNT/Applications"
/usr/bin/install -m 644 "$ROOT_DIR/Assets/AppIcon.icns" "$DMG_MOUNT/.VolumeIcon.icns"
/usr/bin/xattr -cr "$DMG_MOUNT/matveevVpn.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DMG_MOUNT/matveevVpn.app"
/bin/rm -rf "$DMG_MOUNT/.fseventsd"
/bin/sync
/usr/bin/hdiutil detach "$DEVICE" >/dev/null
DEVICE=""

/usr/bin/hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$OUTPUT_DMG" >/dev/null
/usr/bin/hdiutil verify "$OUTPUT_DMG" >/dev/null

echo "Built: $OUTPUT_DMG"
/usr/bin/shasum -a 256 "$OUTPUT_DMG"
