# matveevVpn 1.1.4

- The app now closes itself as soon as Sparkle has prepared an update for
  installation. A short fallback handles cases where AppKit does not complete
  the normal termination request.
- Live download and upload rates were removed from the menu bar quick-access
  menu. The full traffic graph remains in the main window.

This release includes the DNS routing fix from 1.1.3. Users upgrading from a
controller older than version 3 still need one administrator confirmation from
the in-app system-component Update button. Settings, subscription, selected
node, mode and routing rules are preserved.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
