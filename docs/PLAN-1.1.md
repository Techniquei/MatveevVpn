# Release 1.1

Implementation checklist. Checked items are implemented; local automated checks
and the DMG build pass. Installed-app network behavior still needs a real Mac run.

- [x] Versioned, private persistent storage and one-time canonical ~/VPN migration.
- [x] Stable node identity and transactional subscription/configuration changes.
- [x] Native initial setup and subscription editing; no Terminal setup.
- [x] Selective / All Traffic with IPv4, IPv6, DNS and LAN handling.
- [x] Domain wildcards and application bundle/process-path routing.
- [x] Automatic local status, explicit connection diagnostics, clear reset actions.
- [x] Menu bar, launch at login, failure notifications and diagnostic export.
- [x] Node reachability checks and configuration import/export without secrets.
- [x] Signed Sparkle update integration and release pipeline.
- [x] Separate app/controller/schema versions; settings-preserving uninstall.
- [x] Migration, rollback, routing and controller tests; DMG build.

Architecture: views → main-actor presentation model → serialized configuration
service → private state store / subscription parser / system transport. Generated
sing-box configuration is derived state. The root controller owns tunnel lifetime.
User state is committed only after configuration validation and controller acceptance.

Sparkle signing key and GitHub secret are configured. Developer ID/notarization
credentials are not available on this Mac. Public release still requires a real
installed-app run, including upgrade and network behavior. No publication was performed.
