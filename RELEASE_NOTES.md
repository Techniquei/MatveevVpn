# matveevVpn 1.4.0-beta.xray

This opt-in beta replaces the system tunnel with an Xray service.
Stable-only users remain on 1.3.5.

- The privileged component is now the Xray service. It owns the tunnel, DNS
  and routing. Subscriptions and direct links accept VLESS, VMess AEAD,
  Trojan, Shadowsocks, SOCKS and Hysteria2. Legacy VMess QR links, Clash
  configs and raw Xray JSON are not imported as nodes.
- Requires system component version 23. After updating the app, click **Update**
  on the main screen (or **Settings → Repair service…**) and approve the
  administrator prompt. This installs the Xray service and retains the
  subscription, selected server, routing rules and desired connection state.
- Updating the component briefly interrupts the connection. An app update or
  computer restart alone does not replace the privileged service.
- Sites that are not selected for VPN routing stay reachable while the tunnel
  is connected, using the same direct path they use with the VPN off.
- Server latency is measured for every server. The selected server's bypass no
  longer makes the other servers look timed out.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
