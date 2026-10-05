# Architecture

## Xray migration prototype

The production app below still uses the existing controller. The next beta is
being developed on `codex/xray-beta`; its native service is not installed yet.
`Runtime/` contains an internal Go child process linking libXray v26.9.30 and
Xray-core v26.9.30 directly. This avoids embedding a Go runtime in the Swift UI
or introducing an XCFramework boundary for a core that runs in another process.
The Go toolchain and modules are pinned; downloaded tools and binaries stay in
`.build/`. The child accepts bounded newline-delimited JSON on stdin with fixed
start/validate/stop/status actions. It does not accept config paths or credentials
in arguments. Engine errors are returned as fixed codes and engine logs are
disabled in this prototype. `running` describes the core, not tunnel health.
The future supervisor remains responsible for admission, deadlines, health,
system network changes and recovery; this worker is not a public privileged API.

Validation and candidate probes must use a separate idle worker because libXray
construction changes process-wide state. EOF, signals and oversized input stop
the worker and close listeners. Shutdown has a five-second process exit limit;
a native call that hangs cannot keep the child alive indefinitely. The prototype
is exercised with real loopback traffic, without changing host routes or DNS.
The manual-only `--tun-smoke` command creates and releases a temporary utun,
accepts no configuration and adds no default routes or system DNS. It is removed
once the native service acceptance harness covers that lifecycle. See
`docs/XRAY-RUNTIME-CHECK.md` for the pending manual check.
The future Go supervisor, snapshot/IPC semantics and persistent FakeDNS design
are specified in `docs/XRAY-DECISIONS.md`; they are not implemented by this
prototype. `docs/GROK-HANDOFF.md` records the checkpoint and implementation order.

## Current application

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
| Diagnostics / Updater | Node latency, reachability, rule explanation and Sparkle integration |

## State and transactions

The user state schema is version 2. App release, controller protocol and state
schema versions are independent. An app-only replacement does not require
reinstalling the controller. The system component remains necessary for TUN.

Subscription data, node ID, routing mode/rules and desired connection state are
one atomic private JSON file. The parent directory has mode 0700; files have mode
0600. Migration only reads canonical ~/VPN and never searches backups. Once the
new file exists, reinstalling or resetting cannot trigger another migration.

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

DNS interception precedes application/private destination routing. Private
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

Application bundle routing uses an escaped, anchored executable-path expression.
It does not infer parent-process ancestry. Diagnostics may populate an executable
path from a running application and explain configured rules, but do not claim
to observe the actual rule used by an existing socket.

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
TCP handshake as a fallback. The UI displays latency without the probe method. While the VPN is expected to be on, a bounded tunnel-DNS probe
runs every 15 seconds. Three consecutive failures start recovery: two restarts
of the current node, then up to three alternate nodes ordered by known TCP
latency. A persistent circuit breaker permits at most three actual node switches
in ten minutes. Exhausting a recovery cycle surfaces an error and schedules the
next cycle after 30 seconds without clearing the desired-on state. The privileged
controller independently retries a failing runtime every 30 seconds, including
when the UI is absent. If startup DNS fails on both the VPN and the explicitly direct
diagnostic domain, the controller keeps the engine alive in `waiting for network`.
Its existing five-second watchdog checks DNS again, so Internet can become available
without an IP or gateway change or another engine restart. If direct DNS recovers but
VPN DNS still fails, normal node retry/failover resumes. `starting` and `waiting for network` leave the app's controls
available and suppress competing UI recovery and startup reconciliation. The app gives
launchd one 15-second startup window before escalating an unpublished initial status.
A healthy tunnel check clears a pending automatic-recovery error even when the controller
restored the connection itself; unrelated user-operation errors remain intact.
A physical-network change after wake clears the delay and triggers the next startup
attempt immediately. Every startup attempt shares one ten-second readiness budget
across TUN and DNS, reserving time for each bounded DNS query. Exceeding that budget
fails the attempt; offline diagnosis and cleanup/rollback follow separately. Both
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
tunnel DNS; it has no fixed initial sleep. Both required engines must stay alive during
these checks, and reload retains its existing rollback on failure. Monotonic millisecond
timings cover configuration generation/validation, runtime launch, DNS readiness and
shutdown (including DNS restoration). They use the existing bounded app/runtime logs;
controller timings are also included in exported runtime diagnostics. No network work
or timing probes were added to the app's status timer.
Fixed actions and settings schema remain unchanged. Controller compatibility version
14 requires the deadline field in commands; installations of version 13 or earlier need
the system component Update action or Repair Service before bounded operations can run.
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
Existing installations display the system component Update action (also available
through Repair Service); health checks and startup reconciliation wait for that
update. Fixed actions and settings schema remain unchanged.

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
