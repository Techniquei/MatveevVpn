# matveevVpn 1.4.0-beta.3.install.1 — manual test build

This build uses the same runtime and network configuration as beta.3 and fixes
system-component installation. It is not published to Releases or the update feed.

- Removes quarantine from staged and installed helper/plist copies while preserving
  the downloaded app and unrelated attributes.
- Verifies arm64 helpers and configuration before stopping an existing component.
- Backs up the full stopped installation, including a previous native Xray service
  without a legacy config.json, and restores it after failed replacement.
- Installs the legacy controller stopped. Settings are committed before connecting,
  so network filtering cannot be reported as a failed system installation.
- Preserves Sparkle helper entitlements when signing the app.

After copying the app to Applications, install or repair the system component.
The expected component version is 27. Internet access through the affected Mac's
corporate endpoint security still requires a separate connection test.
