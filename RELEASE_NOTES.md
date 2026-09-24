# matveevVpn 1.3.4

- Fixes recovery after a network change when macOS reports a `REACH` summary in
  `scutil --nwi`. The controller and DNS manager now select an IPv4 interface
  instead of treating that summary as an interface name.
- Corrects the physical-network status in exported diagnostics for the same case.
- Refines spacing and controls in settings and routing windows while keeping the
  familiar connection, routing and restart controls on the main window.

After updating an existing installation, open **Settings & Diagnostics → Repair
Service…** and approve the administrator prompt. This replaces the installed
system scripts with the corrected versions; the component protocol version did
not change, so the app update alone does not replace them.

Settings, subscription, selected node and routing rules are preserved.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
