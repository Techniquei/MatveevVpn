# Architecture

The app has one shared main-actor presentation model and one main window.
The menu bar uses the same state and traffic monitor as the window.

| Component | Responsibility |
| --- | --- |
| SettingsViews / matveevVpn | UI, confirmation dialogs, traffic chart |
| VPNController | Presentation state and serialized user operations |
| ConfigurationCoordinator | Validate, deploy, commit and recovery boundary |
| Configuration / StateStore | Versioned private state, stable node identity, migration |
| SubscriptionFetcher | Bounded HTTPS transfer without persistent HTTP cache |
| SystemService | Fixed controller protocol, config generation and privileged install |
| build-config.rb | Derive sing-box configuration from node + rules |
| controller.sh | Privileged tunnel lifetime, reload rollback, sleep/network recovery |
| Diagnostics / Updater | Reachability, rule explanation and Sparkle integration |

## State and transactions

The user state schema is version 2. App version (1.1.x), controller protocol version
(2) and schema version are independent. An app-only replacement does not require
reinstalling the controller. The system component remains necessary for TUN.

Subscription data, node ID, routing mode/rules and desired connection state are
one atomic private JSON file. The parent directory has mode 0700; files have mode
0600. Migration only reads canonical ~/VPN and never searches backups. Once the
new file exists, reinstalling or resetting cannot trigger another migration.

Changes follow: parse → generate → sing-box check → private journal → controller
acceptance → atomic settings commit → journal removal. A journal stores the new
state and SHA-256 of the generated configuration. On recovery, state is adopted
only if the controller's active configuration hash matches. Runtime rejection
restores the old config before answering. System installation also backs up and
restores the existing component on startup failure.

An actor rejects overlapping configuration transactions; the shared UI model
disables overlapping user commands across windows and menu controls. Temporary
files contain credentials but are private and removed when the operation exits.
Subscription URLs are never passed in process arguments or error text.

## Routing and diagnostics

DNS interception precedes application/private destination routing. Private
destinations are excluded from TUN so LAN and mesh interfaces retain ownership
of their routes. Full mode changes route and DNS finals and uses IPv4-only DNS;
IPv6 is disabled while connected because VLESS nodes do not consistently provide
IPv6 egress.
The VPN server's own bootstrap lookup necessarily uses the direct resolver.

Application bundle routing uses an escaped, anchored executable-path expression.
It does not infer parent-process ancestry. Diagnostics may populate an executable
path from a running application and explain configured rules, but do not claim
to observe the actual rule used by an existing socket.

The runtime status file is a heartbeat in controller v2. A stale heartbeat is not
reported as connected. External IP checks are separate, bounded requests. They
run after changes or on explicit request, never on the two-second status timer.

## Platform boundaries

One user owns the system controller command directory. This is not a multi-user
VPN service. The privileged controller accepts only fixed actions and treats
configuration as user-owned input validated by sing-box. Ordinary drag-to-Trash
cannot remove a privileged launch daemon; the in-app Uninstall action performs
that cleanup and then moves the application to Trash.

Sparkle replaces only the app. A changed system protocol prompts for a separate
component update. Developer ID/notarization and live network acceptance require
an appropriately configured Mac; compilation does not substitute for those tests.
