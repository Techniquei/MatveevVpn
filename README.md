# matveevVpn

A native VLESS VPN client for Apple Silicon Macs running macOS 13 or newer.

## Version 1.1

- Selective routing or All Traffic mode, including IPv4 and IPv6.
- Native subscription setup, refresh and node selection.
- Domain patterns, process names and application bundle rules including helpers.
- Settings survive replacing or reinstalling the application.
- Download/upload graphs, menu bar controls and optional launch at login.
- Connection diagnostics, node TCP checks and routing-rule explanations.
- Signed Sparkle updates, with manual Check for Updates.
- No bundled subscription or service-specific routing defaults.

## Install

Download the DMG from [Releases](https://github.com/Techniquei/MatveevVpn/releases),
drag the app to Applications and open it. Choose **Install and set up**, enter
your HTTPS VLESS subscription URL, load nodes, select a node and install.

macOS requests an administrator password for system installation, repair or
system-component upgrades. Normal on/off, node, subscription and routing changes
do not request a password. This development build is ad-hoc signed; it is not
notarized by Apple. On macOS versions that block it, review the blocked-app
entry in System Settings → Privacy & Security.

The first upgrade from 1.0 to 1.1 must be installed manually. Subsequent releases
can be installed through Sparkle.

## Routing

**Selective** sends matching traffic through the VPN; unmatched traffic goes
direct. **All Traffic** sends internet traffic through the VPN and keeps local
destinations direct. Switching modes keeps the selective rules.

In Routing Rules, enter one domain or process name per line.
Both `example.com` and `*.example.com` include the base domain and all its
subdomains, but not `notexample.com`. URLs and middle-of-domain wildcards are
rejected.

**Add Application** generates an escaped path expression for the selected
application bundle. For example, a Cursor bundle rule includes its internal
helpers even when their process names vary. Commands launched outside the app
bundle, such as a system shell or an external runtime, need domain rules or their
own explicit rules. Domain routing depends on DNS mapping or a visible protocol
hostname; encrypted hostnames and existing connections can limit domain matching.

DNS port 53 is intercepted before private-network and application rules.
Full mode uses VPN DNS; resolving the VPN server itself uses the macOS system
resolver over the direct connection. Full mode is not a kill switch: turning the VPN off
restores direct connectivity.

## Settings and diagnostics

User state is stored privately in
`~/Library/Application Support/matveevVpn/settings.json`.
It contains sensitive subscription credentials; do not share it.
A one-time migration reads the canonical `~/VPN` installation, preserves the
selected node and rules, and leaves the old files intact. Backup folders are not
searched.

Connection Settings lets you change the URL, refresh nodes and apply a selected
node. Failed changes retain the previous configuration. Node identity is based
on connection parameters, not its position in the list.

Settings & Diagnostics includes IPv4/IPv6 probes, service repair, a copyable
report, application/domain rule explanations, and rules import/export.
Exports do not contain the subscription or node credentials. Public IP probes
contact api4.ipify.org and api6.ipify.org only on request or after connection
changes and are always routed through the selected VPN node; they do not prove
the absence of every possible leak. Node tests measure TCP reachability
through the current connection, not authenticated VPN speed.

**Revert Changes** discards unsaved routing edits. **Clear All** clears the editor
after confirmation; Save and Apply commits it. **Reset All Settings** disconnects
and clears the saved subscription, node and rules. **Uninstall** removes the
system service and moves the app to Trash while keeping user settings.

## Build and test

Install Xcode command-line tools, then run:

```sh
./Scripts/validate.sh
./Scripts/build-dmg.sh
```

The build downloads pinned, SHA-256-verified sing-box 1.13.19 and Sparkle 2.9.6.
No Xcode project is required. The output is in `dist/`.
`MATVEEV_SING_BOX_BINARY` can point to an existing arm64 runtime for development.

See [architecture](docs/ARCHITECTURE.md) and [release instructions](docs/RELEASING.md).

## Privacy and licensing

The app has no analytics or bundled account. Subscription requests use a
memory-only HTTP session. Sparkle contacts GitHub for updates. Optional IP checks
contact the provider described above. Diagnostic reports omit subscription URLs,
node credentials and process arguments.

GPL-3.0-or-later. See [third-party notices](THIRD_PARTY_NOTICES.md) and
[security reporting](SECURITY.md).
