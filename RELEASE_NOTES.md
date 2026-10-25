# matveevVpn 1.4.2

Improves connection reliability on networks where DNS replies take longer than
one second. VPN and direct DNS checks run concurrently and allow up to three
seconds per query, while retaining the connection operation and rollback limits.
Xray transport connections resolve their server using IPv4.

Diagnostics no longer include full VLESS connection links. Existing app logs
are sanitized on launch so connection credentials are removed before export.

**Upgrade notes:** Build **1422**, system component **29**. Approve the macOS
administrator prompt once to update the system component and install the DNS
fix. Subscriptions, the selected server and routing settings are preserved.

Requires an Apple Silicon Mac running macOS 13 or later. Available through the
standard update channel.
