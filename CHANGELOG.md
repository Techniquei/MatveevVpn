# Changelog

## 1.1.7

- Removes the unused vertical margins around the main interface and reduces the
  outer margins in the main window and sheets.
- Keeps the notifications toggle selected while macOS permission is requested.
- Synchronizes the saved notification preference with the current system
  permission and explains when notifications are disabled in System Settings.

## 1.1.6

- Fixes a DNS recursion introduced in 1.1.5: the direct/bootstrap resolver now
  reads DNS servers from DHCP instead of calling the overridden macOS resolver.
- Keeps VPN-node hostname resolution independent from the tunnel DNS, restoring
  the bootstrap order used by the working 1.0.4 release.
- Uses a numeric direct DNS-over-HTTPS bootstrap for the VPN node, avoiding both
  blocked UDP resolvers and dependency on the active macOS resolver.
- Adds an explicit tunnel DNS reachability result to Connection Diagnostics.

## 1.1.5

- Works around the macOS sing-box CLI DNS limitation by temporarily assigning
  the tunnel resolver to the active network service while the VPN is on.
- Saves and restores the user's automatic or custom DNS servers on turn-off,
  restart, network changes, service repair and uninstall.
- Keeps the saved DNS state across controller crashes so recovery cannot replace
  the user's original resolver settings with the temporary tunnel address.
- Selects the underlying physical network service even when another macOS VPN
  owns the default route, and watches that interface for network changes.

## 1.1.4

- Automatically terminates the old app process after Sparkle has prepared an
  update, with a short fallback for AppKit termination stalls.
- Removes live traffic rates from the menu bar quick-access menu; the detailed
  download/upload graph remains available in the main window.
- Rejects a cached sing-box binary whose version does not match the release,
  preventing an incompatible runtime from entering a DMG.

## 1.1.3

- Updated sing-box to 1.14.0 and enabled native TUN DNS hijacking on macOS so
  the active resolver no longer remains the local router.
- Restored `prefer_ipv4`; using `ipv4_only` for browser DNS queries could surface
  false NXDOMAIN results.
- Re-resolves VPN-routed destinations through VPN DNS after protocol sniffing,
  preventing locally filtered or poisoned DNS answers from being sent through
  an otherwise healthy tunnel.
- Applies secure destination resolution to domain, application and path rules,
  and to every sniffed hostname in All Traffic mode.

## 1.1.2

- Restored the proven IPv4-only TUN layout from 1.0.4 after real-world logs
  showed unsupported IPv6 destinations stalling application connections.
- DNS now returns IPv4 results only while the VPN is active.
- Private IPv4 networks bypass TUN again, preserving LAN and mesh routes.
- Diagnostics compare an explicitly direct IPv4 probe with an explicitly
  VPN-routed IPv4 probe.

## 1.1.1

- Restored reliable VPN-node hostname bootstrap through the macOS system
  resolver instead of requiring direct UDP access to 1.1.1.1.
- Added regression coverage preventing an external bootstrap DNS dependency.
- Made the diagnostic IPv4/IPv6 probes explicitly use the VPN in Selective mode.
- Automatically reconciles an older generated config after an app-only update,
  without reinstalling the privileged controller.

## 1.0.4

- Automatically restores the tunnel after Mac sleep, network-interface changes,
  or an unexpectedly missing TUN interface.
- Clean restarts remove only stale routes belonging to matveevVpn's own TUN and
  refresh the macOS DNS cache before recreating the tunnel.
- Applies routing and node changes transactionally and restores the last working
  configuration if the new sing-box process cannot start.

## 1.0.3

- Added native node selection from the saved subscription.
- Node changes are validated and applied without Terminal or an administrator
  password.

## 1.0.2

- Changed traffic lines to a step graph so peaks stay vertical instead of
  leaning between samples.
- Made upload traffic a distinct pink line matching its speed label.

## 1.0.1

- Documented the domain rules commonly needed for YouTube.
- The app now detects completed setup automatically when it becomes active.
- Initial service startup now waits for macOS and sing-box readiness instead of
  failing after a fixed three-second delay.

## 1.0.0

- First public release.
- Native English macOS interface.
- Selective VLESS routing by domain suffix and application process name.
- Editable rules with validation and live application.
- Passwordless normal operation after the one-time privileged setup.
- Stable 60-second tunnel traffic graph with explicit byte-per-second labels.
- Embedded uninstall action and clean DMG distribution.
# 1.1.0

- Persistent private settings, canonical 1.0 migration and stable node identity.
- Native subscription setup, refresh and editing; remove Terminal setup.
- Transactional configuration commits, rollback and interrupted-change recovery.
- Selective / All Traffic, IPv6, DNS ordering and application path rules.
- Wildcard domains, clear/revert routing actions and explicit settings reset.
- Menu bar controls, login launch, failure notifications and node reachability.
- Connection diagnostics, rule explanations and credential-free rules export.
- Sparkle signed updates and signed release appcast pipeline.
