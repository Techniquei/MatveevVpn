# matveevVpn 1.3.1

- Keeps retrying VPN startup with a 30-second delay after failures, including
  after system startup and sleep, without automatically turning the VPN off.
- Retries immediately when a physical-network change is detected after wake.
- Preserves the limit on frequent node switches while allowing later recovery
  attempts to continue.
- Reopens the main window when the Dock icon is clicked after closing the window.
- Updates the system controller to version 11.

Settings, subscription, selected node and routing rules are preserved.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
