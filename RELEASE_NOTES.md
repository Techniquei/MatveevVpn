# matveevVpn 1.2.3

- Restores the system DNS override in Selective mode because preserving physical DNS could intermittently make routed sites unreachable on macOS.
- Reports the VPN as running only after its VPN-routed tunnel DNS probe responds.
- Prevents the temporary connected state in which selectively routed sites may not open while DNS is still initializing.
- Records an explicit startup failure when tunnel DNS misses its readiness deadline.
- Allows up to 15 seconds for controller commands and service installation to complete the additional check.

Settings, subscription, selected node, mode and routing rules are preserved when
updating from 1.2.2. The system controller is upgraded to version 9 and requires
one administrator confirmation through Update/Repair Service.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
