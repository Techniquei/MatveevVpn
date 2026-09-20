# matveevVpn 1.3.2

- Adds Stop Recovery to the main window and menu bar. It cancels automatic
  retry/failover, turns the desired VPN state off and unlocks the interface.
- Records unexpected sing-box and Xray exits, including their exit status, in a
  diagnostic snapshot that the application can export without administrator
  access.
- Includes available privileged runtime diagnostics in exported logs.
- Preserves the latest runtime failure after stopping recovery and includes the
  underlying installer output when setup fails.
- Names exported logs with the local date and time, for example
  `matveevVpn-2026-09-20_16-30-45.log`.
- Updates the system controller to version 12.

Settings, subscription, selected node and routing rules are preserved.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
