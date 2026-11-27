# matveevVpn 1.4.3-beta.8

Paste a direct `hysteria2://` or `hy2://` link, or import an HTTPS subscription containing Hysteria 2 servers. Subscriptions can mix VLESS and Hysteria 2, and the Happ compatibility setting also imports Hysteria 2 from Happ JSON.

Hysteria 2 connects over QUIC and verifies the server certificate against `pinSHA256` when the link includes a fingerprint. This beta bundles sing-box 1.15.0-alpha.14 for certificate fingerprint support.

Build **1431**, system component **33**. macOS asks for administrator approval to update the system component.
