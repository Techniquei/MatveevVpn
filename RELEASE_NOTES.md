# matveevVpn 1.4.0

Stable release of 1.4.0-beta.6, including the redesigned interface, streamlined
setup, modern REALITY/XHTTP support and improved startup and recovery from the
1.4.0 beta series.

- Redesigned main window, settings and routing controls, with a Change server
  shortcut and visible background connection progress.
- Automatically installs the system component during first-run setup and updates
  older components at launch. If authorization is cancelled or installation
  fails, relaunch the app to retry.
- Uses native Xray-core for modern REALITY and XHTTP, alongside sing-box for TUN
  and routing. Failed component installation restores the previous installation.
- Simplifies Custom rules to a Domains editor. Saved custom domains are preserved;
  application-name and executable-path routing rules are removed.

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

**Routing change for 1.3.5 users:** In Selective mode, traffic previously matched
only by an application-name or executable-path rule now goes directly unless
covered by a domain rule or service preset. Use domains or presets to route it
through the VPN.

The underlying cause of direct-DNS stalls reported on a Mac with Kaspersky is
still under investigation. This release fixes startup, recovery and status
handling; it does not change the DNS transport.

Requires an Apple Silicon Mac running macOS 13 or later. Available through the
standard update channel. Build **1420** updates both stable 1.3.5 and all 1.4.0
betas, including beta.6.
