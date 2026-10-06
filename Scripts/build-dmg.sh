#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.4.0-beta.xray.1"
BUILD_NUMBER="1414"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-$(/usr/bin/tr -d '\n' < "$ROOT_DIR/Resources/sparkle-public-key.txt")}"
HAGEZI_COMMIT="bc57a04f9f516be32f3d7853feedb0e1d068187e"
HAGEZI_RULES_SHA256="8a4f9ec58dca9b558096763d3753cb9f28d498faac0942e2481cc58cc39e19da"
HAGEZI_LICENSE_SHA256="3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
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

mkdir -p "$DIST_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources/.payload/rules"

echo "Compiling matveevVpn $VERSION..."
/bin/bash "$ROOT_DIR/Scripts/fetch-sparkle.sh"
mkdir -p "$APP/Contents/Frameworks"
/usr/bin/ditto "$ROOT_DIR/.build/sparkle/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Compile a fixed source snapshot: filesystem metadata in Documents can change
# while swiftc reads the working directory, even when source bytes are unchanged.
/usr/bin/ditto --noextattr --noqtn "$ROOT_DIR/Sources" "$WORK_DIR/Sources"
/usr/bin/xcrun --sdk macosx swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macos13.0 \
  -F "$ROOT_DIR/.build/sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$WORK_DIR"/Sources/*.swift \
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
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  /usr/bin/plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$INFO_PLIST"
  /usr/bin/plutil -insert SUFeedURL -string 'https://github.com/Techniquei/MatveevVpn/releases/latest/download/appcast.xml' "$INFO_PLIST"
  /usr/bin/plutil -insert SUEnableAutomaticChecks -bool true "$INFO_PLIST"
fi

/usr/bin/install -m 644 "$ROOT_DIR/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/install -m 755 "$ROOT_DIR/Resources/payload/uninstall-service.sh" "$APP/Contents/Resources/.payload/uninstall-service.sh"
/usr/bin/install -m 644 "$ROOT_DIR/Resources/README.txt" "$APP/Contents/Resources/README.txt"
/usr/bin/install -m 644 "$ROOT_DIR/LICENSE" "$APP/Contents/Resources/LICENSE"
/usr/bin/install -m 644 "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
/usr/bin/install -m 644 "$ROOT_DIR/.build/sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE"

HAGEZI_RULES="$WORK_DIR/hagezi-pro-mini.txt"
HAGEZI_LICENSE="$WORK_DIR/Hagezi-LICENSE"
if [[ -n "${MATVEEV_HAGEZI_RULES:-}" ]]; then
  [[ -n "${MATVEEV_HAGEZI_LICENSE:-}" && -f "$MATVEEV_HAGEZI_RULES" && -f "$MATVEEV_HAGEZI_LICENSE" ]] || { echo "Local HaGeZi rules and license are both required" >&2; exit 1; }
  echo "Using local HaGeZi rules..."
  /bin/cp "$MATVEEV_HAGEZI_RULES" "$HAGEZI_RULES"
  /bin/cp "$MATVEEV_HAGEZI_LICENSE" "$HAGEZI_LICENSE"
else
  echo "Downloading pinned HaGeZi Multi PRO mini rules..."
  /usr/bin/curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
    "https://raw.githubusercontent.com/hagezi/dns-blocklists/$HAGEZI_COMMIT/wildcard/pro.mini-onlydomains.txt" -o "$HAGEZI_RULES"
  /usr/bin/curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
    "https://raw.githubusercontent.com/hagezi/dns-blocklists/$HAGEZI_COMMIT/LICENSE" -o "$HAGEZI_LICENSE"
fi
[[ "$(/usr/bin/shasum -a 256 "$HAGEZI_RULES" | /usr/bin/awk '{print $1}')" == "$HAGEZI_RULES_SHA256" ]] || { echo "HaGeZi rules checksum mismatch" >&2; exit 1; }
[[ "$(/usr/bin/shasum -a 256 "$HAGEZI_LICENSE" | /usr/bin/awk '{print $1}')" == "$HAGEZI_LICENSE_SHA256" ]] || { echo "HaGeZi license checksum mismatch" >&2; exit 1; }
/usr/bin/install -m 644 "$HAGEZI_RULES" "$APP/Contents/Resources/.payload/rules/hagezi-pro-mini.txt"
/usr/bin/install -m 644 "$HAGEZI_LICENSE" "$APP/Contents/Resources/Hagezi-LICENSE"
/usr/bin/install -m 755 "$ROOT_DIR/Resources/payload/install-service.sh" "$APP/Contents/Resources/.payload/install-service.sh"
/usr/bin/install -m 644 "$ROOT_DIR/Resources/payload/com.matveev.vpn.plist" "$APP/Contents/Resources/.payload/com.matveev.vpn.plist"
/usr/bin/install -m 755 "$ROOT_DIR/Resources/payload/service-lifecycle.sh" "$APP/Contents/Resources/.payload/service-lifecycle.sh"
/bin/bash "$ROOT_DIR/Scripts/build-xray-runtime.sh"
/usr/bin/install -m 755 "$ROOT_DIR/.build/xray-runtime/matveev-xray-service" "$APP/Contents/Resources/.payload/matveev-xray-service"
/usr/bin/install -m 755 "$ROOT_DIR/.build/xray-runtime/matveev-xray-worker" "$APP/Contents/Resources/.payload/matveev-xray-worker"
for module in xray-core libxray; do
  MODULE_DIR="$(GOTOOLCHAIN=local GOPATH="$ROOT_DIR/.build/go" "$ROOT_DIR/.build/toolchains/go1.27.1/bin/go" list -C "$ROOT_DIR/Runtime" -mod=readonly -m -f '{{.Dir}}' "github.com/xtls/$module")"
  [[ -f "$MODULE_DIR/LICENSE" ]] || { echo "Pinned $module license is missing" >&2; exit 1; }
  /usr/bin/install -m 644 "$MODULE_DIR/LICENSE" "$APP/Contents/Resources/$module-LICENSE"
done

/usr/bin/xattr -cr "$APP"
SIGN_ARGS=(--force --sign "${CODE_SIGN_IDENTITY:--}")
if [[ -n "${CODE_SIGN_IDENTITY:-}" && "$CODE_SIGN_IDENTITY" != - ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
# --deep does not discover executables in Resources/.payload. Sign every
# helper explicitly, including the new service and worker, then their bundles.
for name in matveev-xray-service matveev-xray-worker; do
  /usr/bin/lipo "$APP/Contents/Resources/.payload/$name" -verify_arch arm64
  /usr/bin/codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/.payload/$name"
  /usr/bin/codesign --verify --strict "$APP/Contents/Resources/.payload/$name"
done
while IFS= read -r -d '' executable; do
  if /usr/bin/file -b "$executable" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/codesign "${SIGN_ARGS[@]}" --preserve-metadata=identifier,entitlements,flags "$executable"
  fi
done < <(/usr/bin/find "$APP/Contents/Frameworks" -type f -print0)
while IFS= read -r -d '' bundle; do
  /usr/bin/codesign "${SIGN_ARGS[@]}" --preserve-metadata=identifier,entitlements,flags "$bundle"
done < <(/usr/bin/find "$APP/Contents/Frameworks" -depth -type d \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) -print0)
/usr/bin/lipo "$APP/Contents/MacOS/matveevVpn" -verify_arch arm64
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo "Creating DMG..."
mkdir -p "$DMG_MOUNT"
/usr/bin/hdiutil create -size 256m -fs HFS+ -volname matveevVpn -ov "$RW_DMG" >/dev/null
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
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ -n "${CODE_SIGN_IDENTITY:-}" && "$CODE_SIGN_IDENTITY" != - ]] || { echo 'Notarization requires CODE_SIGN_IDENTITY.' >&2; exit 1; }
  /usr/bin/codesign --timestamp --sign "$CODE_SIGN_IDENTITY" "$OUTPUT_DMG"
  /usr/bin/xcrun notarytool submit "$OUTPUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$OUTPUT_DMG"
fi

echo "Built: $OUTPUT_DMG"
/usr/bin/shasum -a 256 "$OUTPUT_DMG"
