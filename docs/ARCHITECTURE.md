# Architecture

The app has one shared main-actor presentation model and one main window.
Subscription, settings and routing editors use separate, movable native windows.
Each editor has one window instance. Closing and reopening subscription setup
resets its draft; focusing an already open editor preserves it. Native close
controls are disabled while a serialized user operation is running.
The main window displays servers directly in a scrollable list. Its current server
stays pinned above the scrolling alternatives; both derive from the saved node ID.
Clicking a server commits its ID and desired-on state together through the coordinator.
The menu bar uses the same state as the window. The window measures tunnel traffic
with a shared speed monitor.
All app windows share the same dark palette and compact header. Server rows use
the main content margin directly, without an additional inset panel.

| Component | Responsibility |
| --- | --- |
| SettingsViews / matveevVpn | UI, confirmation dialogs, traffic indicators |
| VPNController | Presentation state and serialized user operations |
| ConfigurationCoordinator | Validate, deploy, commit and recovery boundary |
| Configuration / StateStore | Versioned private state, stable node identity, migration |
| SubscriptionFetcher | Bounded HTTPS transfer without persistent HTTP cache |
| SystemService | Fixed controller protocol, config generation and privileged install |
| build-config.rb | Derive sing-box configuration and the optional REALITY sidecar |
| controller.sh | Privileged tunnel lifetime, reload rollback, sleep/network recovery |
| Diagnostics / Updater | Node latency, reachability and Sparkle integration |

## State and transactions

The user state schema is version 2. App release, controller protocol and state
schema versions are independent. An app-only replacement does not require
reinstalling the controller. The system component remains necessary for TUN.

If the installed component version differs at startup, the presentation model
automatically runs the serialized component installation with the saved settings
and desired connection state. It displays progress while macOS requests
administrator authorization. Each launch makes one automatic attempt; cancellation
or failure leaves the error visible and retries on the next launch, without a
separate Update button. Compatible components do not prompt. Unreadable settings
prevent automatic replacement. Configuration controls wait for the required
component, while disconnecting the old tunnel remains available after failure.

Subscription data, node ID, routing mode/rules and desired connection state are
one atomic private JSON file. The parent directory has mode 0700; files have mode
0600. Migration only reads canonical ~/VPN and never searches backups. Once the
new file exists, reinstalling or resetting cannot trigger another migration.

Custom routing stores only domains alongside routing mode, service presets and
ad-blocking preferences. Older application-name and executable-path fields are
ignored when decoding and omitted when saving. Saved custom domains are preserved
even if they match the obsolete bundled domain list.

Changes follow: parse → generate → engine checks → private journal → controller
acceptance → atomic settings commit → journal removal. A journal stores the new
state and SHA-256 of the generated configuration. On recovery, state is adopted
only if the controller's active configuration hash matches. Runtime rejection
restores the old config before answering. System installation also backs up and
restores the existing component on startup failure. First installation starts
the service stopped, commits the validated configuration, then requests the
connection separately. A connection failure keeps the committed subscription so
the user can retry without another administrator prompt.

First-run setup installs the component automatically when its window first appears.
The coordinator provisions an empty, stopped configuration before any subscription
is requested. The builder's zero index is accepted only for an empty subscription;
that configuration has no listener, TUN or DNS policy. Installation failure removes
the partial component, so cancellation and retry cannot advance setup prematurely.
The installer window displays indeterminate progress while macOS handles authorization.
After installation, one serialized user operation loads and validates the subscription,
selects its first node and applies it through the coordinator without reinstalling.
Editing an existing subscription retains a matching node; a missing previous node
requires an explicit replacement. Compatibility options remain available in a disclosure.

An actor rejects overlapping configuration transactions; the shared UI model
disables overlapping user commands across windows and menu controls. Temporary
files contain credentials but are private and removed when the operation exits.
Subscription URLs are never passed in process arguments or error text.

## Routing and diagnostics

The controller records the last successful remote preset download or HTTP 304
in `control/routing-updated-at`, using sing-box 1.14 INFO success events. Remote
preset configurations enable INFO logging; logs retain their existing size limit.
This optional, non-sensitive epoch timestamp survives log rotation and runtime
restarts. The app reads it when opening the routing editor, never on the status
timer. It means the most recent successful preset refresh, not completion of
every selected preset. Older installed components without this metadata display
an unavailable date; cache-file modification time is not used as a substitute.

Custom rules accept one domain per line. `example.com` and `*.example.com` both
match the base domain and all subdomains. The editor validates these entries;
the builder generates domain-suffix rules for DNS and VPN routing.

DNS interception precedes domain/private destination routing. Private
destinations are excluded from TUN so LAN and mesh interfaces retain ownership
of their routes. Full mode changes route and DNS finals and prefers IPv4 DNS;
IPv6 is disabled while connected because VLESS nodes do not consistently provide
IPv6 egress.
sing-box 1.14 native TUN DNS hijacking installs the derived tunnel DNS endpoint.
The controller temporarily assigns that endpoint to the active physical network
service in both routing modes because native TUN DNS alone is intermittent in
sing-box CLI mode on macOS. The previous DNS configuration is restored when the
tunnel stops.
After sniffing, hostnames selected for VPN routing are resolved through `dns-vpn`
before the terminal outbound rule. This replaces locally filtered destination
addresses. Other hostnames and the VPN server itself use a numeric direct
DNS-over-HTTPS resolver. It does not read the macOS resolver after that resolver
has been replaced by the tunnel endpoint, avoiding a circular DHCP lookup.
For REALITY and XHTTP nodes, Xray-core owns only the VLESS transport on a loopback SOCKS
endpoint because current servers can reject the legacy client version
advertised by sing-box. sing-box still owns TUN, DNS and routing; an explicit
process rule keeps the Xray uplink outside the tunnel. The primary configuration
contains a hash marker for the private Xray sidecar, preserving transaction identity.

The runtime status file is a heartbeat in controller v2. A stale heartbeat is not
reported as connected. External IP checks are separate, bounded requests. They
run after changes or on explicit request, never on the two-second status timer.

Node latency is measured automatically when the app starts and again when a
node is selected. The selection probe runs in the background after the configuration
transaction finishes, so it does not delay unlocking user operations. A new individual
probe cancels the previous one; cancelled probes do not publish their results.
The four concurrent workers in a latency batch share a fifteen-second deadline;
no further nodes are queued after it expires, and each probe uses the remaining budget.
Probes are bound to the physical network interface so the TUN
cannot report a local connect time for an alternate node. Three ICMP packets
provide the average RTT; nodes that block ICMP use one direct, interface-bound
TCP handshake as a fallback. The UI displays latency without the probe method.
The privileged controller owns current-node restarts and checks both explicitly
routed DNS paths every five seconds. `running` requires live required engines, TUN,
applied system DNS, physical IPv4 routing, VPN DNS and direct DNS. The diagnostic
domains disable DNS caching so a previous successful answer cannot mask a broken
resolver connection. Interface byte counters measure attempted traffic, not site
availability; successful DNS probes do not guarantee that every site is reachable. A failed direct
path with working VPN DNS publishes `waiting for direct DNS` and keeps the engine
alive. Failures on both paths publish `waiting for network`; neither state starts
node failover. Three consecutive VPN-only DNS failures trigger one controlled
restart. A failed node start with working direct DNS publishes `waiting to retry`
and retries after 30 seconds, including while the UI is absent.

The UI owns alternate-node selection, eligible only in `waiting to retry`. It
tries up to three alternate nodes ordered by known latency within one fifteen-second
cycle. A persistent circuit breaker permits at most three actual node switches in
ten minutes. A failed cycle surfaces an error and waits 30 seconds before trying
again. `starting`, `recovering` and the DNS/network waiting states suppress competing
app recovery and keep manual controls available. The UI publishes service status
independently of foreground busy state, showing a spinner and the specific waiting
reason while desired-on has not reached readiness, including after reboot or a
failed manual Connect. Disconnect remains enabled. The menu bar and the power
button accessibility value use the same status text. Background success clears
the last manual connection error while preserving unrelated settings errors. Managed stop/start sequences
publish `recovering`, never intermediate `stopped`. An `on` or `restart` accepted
for background network/DNS readiness returns `pending`; the app displays the
specific waiting state without a configuration-rejection error. Actual command
failures use command-specific messages; only rejected reloads mention configuration
rollback.

Startup before a physical IPv4 address and scoped default route waits without
creating engines or changing system DNS. Desired-on persists until network readiness
allows startup. This background wait has no total timeout and can be cancelled by
turning the VPN off. Blocking controller work is excluded from the loop-gap watchdog;
changes to the kernel's `kern.waketime` separately detect wake, including sleep
inside a command or startup attempt.
A healthy tunnel check clears a pending automatic-recovery error even when the controller
restored the connection itself; unrelated user-operation errors remain intact.
A physical-network change after wake clears the delay and triggers the next startup
attempt immediately. Every startup attempt shares one ten-second readiness budget
across TUN and DNS, reserving time for each bounded DNS query. Exceeding that budget
ends the foreground attempt; background waiting retains live engines for network/DNS delays. Both
engines receive TERM together and share one five-second shutdown grace, polled every
100 ms. User operations and each automatic-recovery cycle have one fifteen-second
deadline shared by configuration generation/validation, controller actions, probes and
rollback. Each command carries its absolute expiry, so queueing does not reset the
budget. The controller converts the remaining time to a monotonic deadline and leaves
one second for acknowledgement and settings commit. Reload reserves half its remaining
time for rollback; failed startup cleanup shares that attempt's deadline, and cleanup
kills engines that outlive the remaining grace. A restored
configuration can remain stopped for the watchdog to retry when its readiness budget
is exhausted. Validation/probe subprocesses are terminated at their remaining deadline.
Failure-context collection runs after UI unlocking. The macOS administrator dialog and
privileged install/uninstall are separate OS lifecycle operations; their existing
transaction/authorization handling is preserved.
Startup checks TUN readiness immediately and polls for up to six seconds, then confirms
both tunnel DNS paths; it has no fixed initial sleep. Both required engines must stay alive during
these checks, and reload retains its existing rollback on failure. Monotonic millisecond
timings cover configuration generation/validation, runtime launch, DNS readiness and
shutdown (including DNS restoration). They use the existing bounded app/runtime logs;
controller timings are also included in exported runtime diagnostics. No network work
or timing probes were added to the app's status timer.
Fixed actions and settings schema remain unchanged. Controller compatibility version
14 requires the deadline field in commands; installations of version 13 or earlier
are updated automatically at launch before bounded operations can run.
Watchdog timestamps are recorded after controller work finishes, so a slow startup or
reload is not mistaken for sleep and followed by another restart.

The user-readable event log lives under `~/Library/Logs/matveevVpn`. Each append
atomically retains at most 3,000,000 bytes, and Settings or an error action exports its bytes
unchanged. It is deliberately unredacted and may contain node addresses, links
and credentials; filesystem permissions are 0600. Failure entries include the
physical network state, Wi-Fi power, default route, VLESS URI, endpoint,
transport, security, flow, runtime core and recent raw engine errors. Privileged
engine output is also written through bounded appenders; each internal runtime
log has the same hard maximum. Each engine stream uses one persistent writer,
with a shared file lock for concurrent writers. Rotation leaves ten percent
headroom to avoid copying a full log for each subsequent INFO line. This keeps
traffic logging from filling the engine output pipe and stalling DNS processing.
The streaming writer remains required for INFO preset telemetry; version 12 cannot
safely consume that configuration under load. Version 14 additionally enforces command
deadlines; it retains the streaming writer introduced in version 13.
Existing installations automatically update an outdated component at launch;
health checks and startup reconciliation wait for that update. Fixed actions and
settings schema remain unchanged.

## Platform boundaries

One user owns the system controller command directory. This is not a multi-user
VPN service. The privileged controller accepts only fixed actions and treats
configuration as user-owned input validated by sing-box. Ordinary drag-to-Trash
cannot remove a privileged launch daemon; the in-app Uninstall action performs
that cleanup and then moves the application to Trash.

Sparkle replaces only the app. A changed system protocol prompts for a separate
component update. Developer ID/notarization and live network acceptance require
an appropriately configured Mac; compilation does not substitute for those tests.
AppUpdater requests normal AppKit termination on the next main-queue turn after
Sparkle's relaunch callback. This lets Sparkle send the install-and-relaunch
instruction first and avoids relying on an external quit event. Preparing an
update or choosing installation on quit does not close the app.

## Update channels

AppUpdater owns the beta preference in app UserDefaults and exposes it directly
as observable UI state. Beta is disabled by default; opting in permits Sparkle's
beta channel alongside its always-available default channel. Changing the setting
reschedules the existing updater cycle. Opting out never downgrades the app.
Both channels use the same signed appcast. A beta release is a GitHub prerelease
and its channel-tagged item is also published into the latest stable release's
appcast so installed clients can discover it. Release jobs are serialized.
