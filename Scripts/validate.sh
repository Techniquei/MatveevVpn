#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(/usr/bin/mktemp -d /private/tmp/matveev-validation.XXXXXX)"
trap '/bin/rm -rf "$TEST_BUILD"' EXIT

/bin/bash -n "$ROOT_DIR/Resources/payload/uninstall-service.sh"
/bin/bash -n "$ROOT_DIR/Resources/payload/controller.sh"
/bin/bash -n "$ROOT_DIR/Resources/payload/dns-manager.sh"
/usr/bin/ruby -c "$ROOT_DIR/Resources/payload/tools/build-config.rb" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Resources/payload/com.matveev.vpn.plist" >/dev/null
/usr/bin/xcrun --sdk macosx swiftc -parse-as-library -typecheck -target arm64-apple-macos13.0 "$ROOT_DIR"/Sources/*.swift
/usr/bin/xcrun swiftc -parse-as-library "$ROOT_DIR/Sources/AppLogger.swift" "$ROOT_DIR/Sources/Updater.swift" "$ROOT_DIR/Tests/UpdaterTests.swift" -o "$TEST_BUILD/updater-tests"
"$TEST_BUILD/updater-tests"
"$ROOT_DIR/Tests/controller-test.sh"
"$ROOT_DIR/Tests/dns-manager-test.sh"
/usr/bin/xcrun swiftc "$ROOT_DIR/Sources/Configuration.swift" "$ROOT_DIR/Tests/ConfigurationTests.swift" -o "$TEST_BUILD/configuration-tests"
"$TEST_BUILD/configuration-tests"
/usr/bin/xcrun swiftc "$ROOT_DIR/Sources/AppLogger.swift" "$ROOT_DIR/Tests/AppLoggerTests.swift" -o "$TEST_BUILD/app-logger-tests"
"$TEST_BUILD/app-logger-tests"
/usr/bin/xcrun swiftc "$ROOT_DIR/Sources/Configuration.swift" "$ROOT_DIR/Sources/AdBlockRuleStore.swift" "$ROOT_DIR/Sources/SystemService.swift" "$ROOT_DIR/Tests/AdBlockRuleStoreTests.swift" -o "$TEST_BUILD/ad-block-rule-tests"
"$TEST_BUILD/ad-block-rule-tests"
/usr/bin/xcrun swiftc "$ROOT_DIR/Sources/Configuration.swift" "$ROOT_DIR/Sources/AdBlockRuleStore.swift" "$ROOT_DIR/Sources/SystemService.swift" "$ROOT_DIR/Sources/Diagnostics.swift" "$ROOT_DIR/Tests/DiagnosticsTests.swift" -o "$TEST_BUILD/diagnostics-tests"
"$TEST_BUILD/diagnostics-tests"
/usr/bin/xcrun swiftc "$ROOT_DIR/Sources/Configuration.swift" "$ROOT_DIR/Sources/AdBlockRuleStore.swift" "$ROOT_DIR/Sources/SystemService.swift" "$ROOT_DIR/Sources/ConfigurationCoordinator.swift" "$ROOT_DIR/Tests/CoordinatorTests.swift" -o "$TEST_BUILD/coordinator-tests"
"$TEST_BUILD/coordinator-tests"
/usr/bin/xcrun swiftc -parse-as-library "$ROOT_DIR/Sources/Configuration.swift" "$ROOT_DIR/Sources/ConfigurationCoordinator.swift" "$ROOT_DIR/Sources/AdBlockRuleStore.swift" "$ROOT_DIR/Sources/Diagnostics.swift" "$ROOT_DIR/Sources/Updater.swift" "$ROOT_DIR/Sources/VPNController.swift" "$ROOT_DIR/Tests/FirstRunBoundaryFakes.swift" "$ROOT_DIR/Tests/FirstRunTests.swift" -o "$TEST_BUILD/first-run-tests"
"$TEST_BUILD/first-run-tests"
/usr/bin/xcrun swiftc -parse-as-library -target arm64-apple-macos13.0 "$ROOT_DIR/Sources/WindowCloseControl.swift" "$ROOT_DIR/Tests/WindowCloseControlTests.swift" -o "$TEST_BUILD/window-close-tests"
"$TEST_BUILD/window-close-tests"
# Keep private UI views private while rendering their actual source in the regression test.
/usr/bin/sed '/^@main$/d' "$ROOT_DIR/Sources/matveevVpn.swift" > "$TEST_BUILD/main-layout.swift"
/bin/cat "$ROOT_DIR/Tests/MainLayoutTests.swift" >> "$TEST_BUILD/main-layout.swift"
/usr/bin/xcrun swiftc -parse-as-library -target arm64-apple-macos13.0 "$ROOT_DIR/Sources/Configuration.swift" "$ROOT_DIR/Sources/ConfigurationCoordinator.swift" "$ROOT_DIR/Sources/AdBlockRuleStore.swift" "$ROOT_DIR/Sources/Diagnostics.swift" "$ROOT_DIR/Sources/Updater.swift" "$ROOT_DIR/Sources/VPNController.swift" "$ROOT_DIR/Sources/SettingsViews.swift" "$ROOT_DIR/Sources/WindowCloseControl.swift" "$ROOT_DIR/Tests/FirstRunBoundaryFakes.swift" "$TEST_BUILD/main-layout.swift" -o "$TEST_BUILD/main-layout-tests"
"$TEST_BUILD/main-layout-tests"
/usr/bin/ruby "$ROOT_DIR/Tests/routing-test.rb"
/bin/bash -n "$ROOT_DIR/Resources/payload/install-service.sh"
/bin/bash -n "$ROOT_DIR/Resources/payload/service-lifecycle.sh"
/bin/bash "$ROOT_DIR/Tests/service-lifecycle-test.sh"

if /usr/bin/grep -Eq 'ByteCountFormatter' "$ROOT_DIR/Sources/matveevVpn.swift"; then
  echo "Unstable speed formatting was reintroduced." >&2
  exit 1
fi

echo "validation: ok"
