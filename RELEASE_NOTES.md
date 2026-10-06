# matveevVpn 1.4.0-beta.xray.2 test build

This is a manual test build. No public release or update-feed entry is published.

Fixes startup when endpoint security rejects the physical DNS-over-HTTPS check
(for example, an HTML block page returned with HTTP 499). A reachable VPN server
can now establish connectivity even when that public DNS provider is blocked.
Stable-only users remain on 1.3.5.

- Falls back to captured DNS on the physical interface for server names and direct
  traffic after a rejected DoH request. VPN DNS queries never use this fallback.
- Checks server connectivity before creating a TUN or changing DNS/routes when
  the public DoH connectivity check fails; tries another reachable node.
- Normalizes LAN subnets so changing ARP/NDP neighbour cache entries do not restart
  the tunnel.
- Exports startup phases and a bounded event history from Xray, including after
  a failed connection is stopped. Avoids exporting stale sing-box logs for Xray.
- Enforces IPC deadlines and handles partial writes and disconnected sockets.
- Retains the quarantined-installation, rollback, signing and arm64 fixes from beta 1.

**After updating the app, click Update on the main screen or Settings → Repair
service… and approve the administrator prompt. System component version 26 is
required.** Updating the app alone does not replace the privileged service.
Subscription, selected server and routing settings are retained.

Requires Apple Silicon and macOS 13 or later. This build is ad-hoc signed and is
not notarized by Apple. The published beta 1 worker passed a privileged native
TUN create/release test. End-to-end connection on the affected Mac still needs
verification after this update.
