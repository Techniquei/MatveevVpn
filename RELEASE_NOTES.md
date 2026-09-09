# matveevVpn 1.1.10

- Adds VLESS XHTTP over REALITY and TLS through the private Xray transport.
- Preserves mode, host, path and raw `extra` JSON from subscription links.
- Supports TLS ALPN lists and the older `splithttp` transport alias.
- Rejects malformed XHTTP parameters before applying a node.

Settings, subscription, selected node, mode and routing rules are preserved when
updating from 1.1.9.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
