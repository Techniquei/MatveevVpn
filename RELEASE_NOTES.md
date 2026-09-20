# matveevVpn 1.3.3

- Restores automatic application relaunch after Sparkle installs an update.
- Fixes a race where system-component updates attempted `launchctl bootstrap`
  while the previous daemon was still terminating, producing `Bootstrap failed:
  5: Input/output error`.
- Waits for daemon removal and retries transient registration failures during
  both installation and rollback.
- Distinguishes a cancelled administrator prompt from a real installation
  failure in the interface.
- Retains the recovery cancellation and expanded diagnostics introduced in
  1.3.2.

Because 1.3.2 contains the relaunch bug, the application may need to be opened
manually once after installing this update. Later updates relaunch normally.

Settings, subscription, selected node and routing rules are preserved.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
