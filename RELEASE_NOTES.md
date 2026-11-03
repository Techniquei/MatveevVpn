# matveevVpn 1.4.3-beta.1

Switching VPN servers on the same network now keeps the existing DNS override.
This avoids repeated system DNS changes and leaves more time for the connection
check. If the active network changes during the restart, the controller applies
DNS to the new network before confirming the connection.

Build **1423**, system component **30**. macOS requests administrator
authorization to upgrade the system component. Requires an Apple Silicon Mac
running macOS 13 or later. Available through the opt-in beta update channel.
