# matveevVpn 1.1.7

- Removes unused outer space from the main window and makes the settings sheets
  more compact.
- Fixes the notifications preference so the toggle stays selected while macOS
  requests permission.
- Keeps the toggle synchronized with the actual macOS notification permission
  and reports when permission must be enabled in System Settings.
- Includes the DNS bootstrap fix from 1.1.6.

No system-component reinstall is required when updating from 1.1.6. Settings,
subscription, selected node, mode and routing rules are preserved.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
