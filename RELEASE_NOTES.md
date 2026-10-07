# matveevVpn 1.4.0-beta.6

More reliable startup and recovery, with visible background connection progress.

- Waits for the physical network and default route before starting the tunnel
  and applying system DNS after boot. The connection starts automatically when
  networking becomes available.
- Checks both VPN and direct DNS before showing the VPN as connected.
  Diagnostic DNS queries bypass cache so an old answer cannot mask a broken
  resolver connection. A direct-DNS failure has its own waiting status.
- Prevents slow startup from triggering a false sleep recovery. Detects wake
  separately, including sleep during a startup operation.
- Keeps current-server recovery in the controller and alternate-server
  selection in the app, avoiding competing restart attempts.
- Shows a spinner and the current connection or waiting state while the service
  works in the background, including after a failed manual connection attempt
  or reboot. Disconnect remains available during background waiting.
- Clears a manual connection error when the service later connects successfully.
- Replaces the configuration-rollback message on Connect with a connection
  status or a command-specific error. Waiting for network or direct DNS is
  acknowledged as an accepted connection request.

**Upgrade notes:** Uses system component **28**. The app updates an older
component on launch; macOS requests administrator authorization. Subscriptions,
selected server and routing settings are preserved.

The underlying cause of direct-DNS stalls reported on a Mac with Kaspersky is
still under investigation. This release fixes startup, recovery and status
handling; it does not change the DNS transport.

Requires an Apple Silicon Mac running macOS 13 or later. Available through the
opt-in beta update channel. The latest stable release remains **1.3.5**.
