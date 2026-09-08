# matveevVpn 1.1.9

- Adds support for modern VLESS REALITY servers that reject the legacy client
  version advertised by sing-box, including the France node used for validation.
- Keeps sing-box in charge of TUN, DNS and selective routing while Xray-core
  handles only the authenticated REALITY transport over a private loopback port.
- Preserves atomic apply, rollback and watchdog recovery across both processes.

A one-time administrator prompt updates the system component from 1.1.8.
Settings, subscription, selected node, mode and routing rules are preserved.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
