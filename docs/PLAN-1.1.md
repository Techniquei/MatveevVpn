# Release 1.1 (historical)

Historical implementation checklist, updated to omit removed features.
See [README](../README.md) for current behavior and
[Releasing](RELEASING.md) for release verification.

- [x] Versioned, private persistent storage and one-time canonical ~/VPN migration.
- [x] Stable node identity and transactional subscription/configuration changes.
- [x] Native initial setup and subscription editing; no Terminal setup.
- [x] Selective / All Traffic with IPv4, DNS and LAN handling. IPv6 was reverted
  after real-world node compatibility failures and remains future work.
- [x] Custom domain rules, including wildcards.
- [x] Automatic local status, explicit connection diagnostics, clear reset actions.
- [x] Menu bar, launch at login, failure notifications and diagnostic export.
- [x] Node reachability checks.
- [x] Signed Sparkle update integration and release pipeline.
- [x] Separate app/controller/schema versions; settings-preserving uninstall.
- [x] Migration, rollback, routing and controller tests; DMG build.

Architecture: views → main-actor presentation model → serialized configuration
service → private state store / subscription parser / system transport. Generated
sing-box configuration is derived state. The root controller owns tunnel lifetime.
User state is committed only after configuration validation and controller acceptance.
