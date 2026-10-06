# matveevVpn

Native VLESS VPN client for Apple Silicon Macs. Requires macOS 13 or newer.

## Features

- Selective routing with per-service presets for commonly restricted services in Russia.
- Custom routing by domain, application name or executable path alongside presets.
- Optional DNS-level advertising and tracker blocking.
- All Traffic mode with private and local networks kept direct.
- Native TUN, DNS interception and VPN-side DNS re-resolution.
- HTTPS subscriptions or direct server links, measured node latency and settings that survive app updates.
- REALITY, XHTTP and the other admitted share links through Xray-core, which also owns TUN, DNS and routing.
- Connection diagnostics, traffic graphs, menu-bar controls and launch at login.
- Atomic configuration reload, automatic rollback and bounded node failover.
- A private application event log capped at 3 MB, exported with a sortable date-and-time filename together with the latest available privileged runtime diagnostics.
- Signed Sparkle update feed.

## Supported server links

Subscriptions may contain plain, standard Base64 or URL-safe Base64-encoded
share links. A mixed list imports the supported entries and skips the rest.
The accepted forms are `vless://`, VMess AEAD `vmess://user@host:port`,
`trojan://`, `ss://`, `socks://`, `hysteria2://` and `hy2://`. Legacy VMess QR
links, Clash configs and raw Xray JSON are not subscription nodes.
The optional **Happ subscription compatibility** setting requests a Happ-specific
response and extracts VLESS outbounds from Happ/Xray JSON subscriptions. It does
so with a stable random device identifier scoped to the provider domain; it does
not use hardware identifiers or import provider-specific routing.

VLESS links use the parameters below. Trojan, VMess, Shadowsocks, SOCKS and
Hysteria2 keep the fields from their own share links.

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
drag `matveevVpn` to Applications and open it. First-run setup automatically
installs the system component and displays progress while macOS requests your
administrator password. It remains stopped, without a tunnel or DNS changes.
Then paste an HTTPS subscription or a direct server link and select **Connect**.
The app loads the subscription and selects its first server automatically, without
a second installation prompt. You can change the server on the main screen.

The system component requires one administrator prompt on first installation or
repair. Normal connection and configuration changes do not require a password.

Service presets use binary rule sets from
[MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat). Selected
sets are downloaded through the VPN, cached locally and checked for updates once
per day. Ad blocking uses the official
[HaGeZi Multi PRO mini](https://github.com/hagezi/dns-blocklists) domain list. A
pinned copy works immediately, then the app validates and refreshes it through
the VPN every eight hours. DNS-level blocking removes many third-party banners,
trackers and ad inserts, but cannot remove ads served from the same domain as the
requested video.

Current builds are ad-hoc signed and not notarized by Apple. If macOS blocks the
app, allow it in System Settings → Privacy & Security. The tunnel is IPv4-only.

## Build

```sh
./Scripts/validate.sh
./Scripts/build-dmg.sh
```

The build compiles the arm64 Xray service and worker from pinned Go modules
and downloads SHA-256-verified Sparkle and HaGeZi artifacts. The legacy sing-box
and standalone Xray CLI binaries are no longer bundled. Output is written to `dist/`.

See [architecture](docs/ARCHITECTURE.md), [release instructions](docs/RELEASING.md)
and [security policy](SECURITY.md).

## Privacy and license

No analytics are included. Subscription credentials and settings remain on the
Mac. Optional IP diagnostics contact ipify only when requested or after a
connection change.

GPL-3.0-or-later. Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
