# matveevVpn 1.2.4

- Prevents a failed Update/Repair Service operation from immediately launching automatic restart and node-failover commands against the controller being rolled back.
- Suppresses automatic recovery for 30 seconds after a failed managed operation, while keeping manual controls available.
- Waits for the previous system controller to become ready before an installer rollback finishes.
- Retains the Selective DNS stability and startup-readiness checks from 1.2.3.

Settings, subscription, selected node, mode and routing rules are preserved when
updating from 1.2.3. The system controller is upgraded to version 10 and requires
one administrator confirmation through Update/Repair Service.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
