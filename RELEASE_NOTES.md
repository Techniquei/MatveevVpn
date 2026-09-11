# matveevVpn 1.2.2

- Adds an optional Happ compatibility mode for User-Agent/HWID-gated subscriptions and imports VLESS nodes from Happ/Xray JSON.
- Uses one stable random device identifier per provider domain instead of reading hardware identity.
- Preserves Wi-Fi or Ethernet DNS settings in Selective mode, reducing interference with OpenVPN and other VPN clients.
- Retains the tunnel DNS override in All Traffic mode and safely restores stale overrides when returning to Selective mode.
- Records physical-network and default-route changes in the bounded runtime log for diagnosing intermittent multi-VPN conflicts.

Settings, subscription, selected node, mode and routing rules are preserved when
updating from 1.2.1. The system controller is upgraded to version 8 and requires
one administrator confirmation through Update/Repair Service.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
