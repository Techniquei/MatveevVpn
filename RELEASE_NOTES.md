# matveevVpn 1.1.6

- Fixes the DNS recursion introduced in 1.1.5 that could make every routed site,
  including ChatGPT, unavailable.
- The VPN node is now resolved through an independent direct DNS-over-HTTPS
  bootstrap with a numeric endpoint. It neither calls the overridden macOS
  resolver nor relies on UDP DNS remaining reachable after TUN starts.
- Ordinary direct domains use the physical network's DHCP DNS, while routed
  domains use encrypted DNS through the selected VPN node.
- Routed domains continue to use encrypted DNS through the selected VPN node.
- Connection Diagnostics now checks the tunnel DNS endpoint directly.
- Includes the reliable app shutdown during Sparkle updates and the simplified
  menu bar quick-access menu from 1.1.4.

No system-component reinstall is required when updating from 1.1.5. Settings,
subscription, selected node, mode and routing rules are preserved.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
