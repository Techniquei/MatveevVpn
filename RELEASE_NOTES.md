# matveevVpn 1.1.5

- Fixes YouTube, Instagram and other blocked domains returning NXDOMAIN while
  the tunnel itself and VPN IP check are working.
- While the VPN is on, macOS now uses the resolver inside the tunnel instead of
  continuing to query the router's DNS server.
- The previous automatic or custom DNS configuration is restored when the VPN
  is turned off, restarted, repaired, moved to another network or uninstalled.
- Includes the reliable app shutdown during Sparkle updates and the simplified
  menu bar quick-access menu from 1.1.4.

This release updates the system controller to version 4, so one administrator
confirmation from the in-app Update button is required. Settings, subscription,
selected node, mode and routing rules are preserved.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
