#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW_DIR="$ROOT_DIR/.build/interaction-preview"
APP="$PREVIEW_DIR/Interaction Preview.app"
mkdir -p "$APP/Contents/MacOS"
sed '/^@main$/d' "$ROOT_DIR/Sources/matveevVpn.swift" > "$PREVIEW_DIR/ui.swift"
cat "$ROOT_DIR/Tests/InteractionPreview.swift" >> "$PREVIEW_DIR/ui.swift"
xcrun swiftc -parse-as-library -target arm64-apple-macos13.0 \
    "$ROOT_DIR/Sources/Configuration.swift" "$ROOT_DIR/Sources/ConfigurationCoordinator.swift" \
    "$ROOT_DIR/Sources/AdBlockRuleStore.swift" "$ROOT_DIR/Sources/Diagnostics.swift" \
    "$ROOT_DIR/Sources/Updater.swift" "$ROOT_DIR/Sources/VPNController.swift" \
    "$ROOT_DIR/Sources/SettingsViews.swift" "$ROOT_DIR/Sources/WindowCloseControl.swift" \
    "$ROOT_DIR/Tests/FirstRunBoundaryFakes.swift" "$PREVIEW_DIR/ui.swift" \
    -o "$APP/Contents/MacOS/InteractionPreview"
/usr/bin/python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({
        'CFBundleIdentifier': 'com.matveev.interaction-preview',
        'CFBundleName': 'Interaction Preview',
        'CFBundleExecutable': 'InteractionPreview',
        'CFBundlePackageType': 'APPL',
        'LSMinimumSystemVersion': '13.0',
    }, file)
PY
echo "$APP"
