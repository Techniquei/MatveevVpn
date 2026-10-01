# matveevVpn 1.4.0-beta.3

This opt-in beta improves connection startup, node switching and recovery.
Stable-only users remain on 1.3.5.

- Connection and configuration operations, including each automatic recovery
  cycle, share a 15-second deadline across validation, startup and rollback.
  Expired commands cannot start a delayed operation. Administrator authorization
  and system component installation remain separate macOS operations.
- When Internet is unavailable during computer startup, the controller keeps
  the tunnel ready and checks again when connectivity returns, even if the
  network address has not changed. The app avoids competing recovery attempts
  and clears an automatic recovery error after the connection becomes healthy.
- Startup checks actual tunnel readiness instead of waiting a fixed second.
  Both engines stop together, with exit checks every 100 ms. Node latency runs
  in the background after switching; batch measurements also have a bounded
  deadline.
- Adds stage durations to existing bounded diagnostic logs for configuration
  validation, startup, DNS readiness and shutdown.
- Fixes termination timing during Sparkle's update-and-relaunch sequence and
  simplifies latency labels.
- Requires system component version 14. After updating the app, click **Update**
  on the main screen (or **Settings → Repair service…**) and approve the
  administrator prompt. This installs the fixed controller and retains the
  subscription, selected server, routing rules and desired connection state.
- Defers automatic health checks and startup configuration reconciliation until
  the incompatible system component has been updated.

Updating the component briefly interrupts the connection. An app update or
computer restart alone does not replace the privileged controller.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
