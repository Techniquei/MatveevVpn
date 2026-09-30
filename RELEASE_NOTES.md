# matveevVpn 1.4.0-beta.2

This is an opt-in beta bug-fix release for connection stalls after updating to
1.4.0-beta.1. Stable-only users remain on 1.3.5.

- Replaces per-line shell logging with a persistent writer so detailed routing
  logs cannot stall the VPN engine by filling its output pipe.
- Keeps private runtime logs capped at 3 MB, with bounded rotation and concurrent
  writer locking. Successful routing refresh timestamps remain available.
- Requires system component version 13. After updating the app, click **Update**
  on the main screen (or **Settings → Repair service…**) and approve the
  administrator prompt. This installs the fixed controller and retains the
  subscription, selected server, routing rules and desired connection state.
- Defers automatic health checks and startup configuration reconciliation until
  the incompatible system component has been updated.

Updating the component briefly interrupts the connection. An app update or
computer restart alone does not replace the privileged controller.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
