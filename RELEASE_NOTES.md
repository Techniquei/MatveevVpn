# matveevVpn 1.2.1

- Measures real node latency with three ICMP probes bound to the physical network interface, bypassing the active VPN tunnel.
- Falls back to a clearly labelled direct TCP handshake when a node blocks ICMP.
- Checks nodes automatically at launch, whenever a node selector opens, and after a node is selected.
- Detects repeated tunnel failures, retries the current node twice and then tries up to three alternate nodes ordered by measured latency.
- Prevents uncontrolled recovery with a persistent limit of three node switches per ten minutes and turns the VPN off with an explicit error when exhausted.
- Adds an unfiltered application log with a strict 3 MB maximum and unchanged file export from Settings and error notifications.
- Records Wi-Fi state, physical interfaces, default route, full VLESS URI, endpoint, transport, security, flow, runtime core and recent raw sing-box/Xray errors when an operation fails.
- Bounds privileged runtime logs to 3 MB and stops the system controller after three consecutive startup failures.
- Removes the obsolete copied diagnostic and error reports.

Settings, subscription, selected node, mode and routing rules are preserved when
updating from 1.2.0. The system controller is upgraded to version 7 and requires
one administrator confirmation through Update/Repair Service.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
