# matveevVpn

Native VLESS VPN client for Apple Silicon Macs. Requires macOS 13 or newer.

## Features

- Selective routing by domain, application name or executable path.
- All Traffic mode with private and local networks kept direct.
- Native TUN, DNS interception and VPN-side DNS re-resolution.
- HTTPS subscriptions or direct VLESS links, measured node latency and settings that survive app updates.
- Modern REALITY and XHTTP through Xray-core; sing-box handles TUN and routing.
- Connection diagnostics, traffic graphs, menu-bar controls and launch at login.
- Atomic configuration reload, automatic rollback and bounded node failover.
- A private application event log capped at 3 MB and exportable unchanged from Settings or an error notification.
- Signed Sparkle update feed.

## Supported VLESS links

Subscriptions may contain plain, standard Base64 or URL-safe Base64-encoded
`vless://` links. Supported VLESS entries are imported from mixed protocol lists.
The optional **Happ subscription compatibility** setting requests a Happ-specific
response and extracts VLESS outbounds from Happ/Xray JSON subscriptions. It does
so with a stable random device identifier scoped to the provider domain; it does
not use hardware identifiers or import provider-specific routing.

| Area | Supported values and parameters |
| --- | --- |
| Server | UUID, hostname or IP, port, node name in the URL fragment |
| Flow | `flow`, including `xtls-rprx-vision` |
| RAW/TCP | omitted `type`, `type=tcp`, `type=raw` |
| WebSocket | `type=ws`, `path`, `host` |
| gRPC | `type=grpc`, `serviceName` |
| XHTTP | `type=xhttp` or `type=splithttp`, `path`, `host`, `mode`, `extra` |
| TLS | `security=tls`, `sni`, `fp`, `alpn` |
| REALITY | `security=reality`, `pbk`, `sid`, `sni`, `fp`, `spx`, optional `pqv` |

XHTTP supports `auto`, `packet-up`, `stream-up` and `stream-one` modes. Its
URL-encoded `extra` value is passed to Xray as a JSON object. ALPN lists such as
`h2,http/1.1` are preserved across TLS transports.

## Install

Download the latest DMG from [Releases](https://github.com/Techniquei/MatveevVpn/releases),
drag `matveevVpn` to Applications and open it. Add an HTTPS subscription or direct VLESS link, choose
a node, then select **Install and set up**.

The system component requires one administrator prompt on first installation or
repair. Normal connection and configuration changes do not require a password.

Current builds are ad-hoc signed and not notarized by Apple. If macOS blocks the
app, allow it in System Settings → Privacy & Security. The tunnel is IPv4-only.

## Build

```sh
./Scripts/validate.sh
./Scripts/build-dmg.sh
```

The build downloads pinned, SHA-256-verified sing-box, Xray-core and Sparkle
artifacts. Output is written to `dist/`.

See [architecture](docs/ARCHITECTURE.md), [release instructions](docs/RELEASING.md)
and [security policy](SECURITY.md).

## Privacy and license

No analytics are included. Subscription credentials and settings remain on the
Mac. Optional IP diagnostics contact ipify only when requested or after a
connection change.

GPL-3.0-or-later. Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
