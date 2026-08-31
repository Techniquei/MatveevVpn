# matveevVpn

A lightweight selective-routing VPN client for Apple Silicon Macs. It turns a
VLESS subscription into a local sing-box configuration and routes only the
domains and applications selected by the user. Everything else stays on the
direct connection.

## Features

- Native SwiftUI interface for macOS 13 and newer.
- Editable domain and application routing rules.
- Live download and upload graph for the VPN tunnel.
- One administrator prompt during initial setup; normal on/off, restart and
  configuration changes do not require a password.
- No bundled subscription, account, analytics or telemetry.
- Clean DMG distribution with one application.

## Install

1. Download `matveevVpn-1.0.2-arm64.dmg` from Releases.
2. Open the DMG and drag `matveevVpn.app` to Applications.
3. On first launch, right-click the app and choose **Open** if macOS displays a
   Gatekeeper warning.
4. Click **Install and set up**, enter a VLESS subscription URL, choose a node,
   and approve the single administrator prompt.

The app stores user configuration in `~/VPN`. The root controller and sing-box
runtime are installed in `/Library/Application Support/matveevVpn`.
Run setup again when you want to replace the subscription or select another node.

## Routing rules

Open **Routing rules…** in the app. Add one domain suffix or application process
name per line, then choose **Save and Apply**. Unmatched traffic remains direct.
The simple rules are stored at `~/VPN/routing-rules.json`; the full sing-box
configuration is generated and validated automatically.

For example, YouTube generally needs `youtube.com`, `youtu.be`,
`youtube-nocookie.com`, `googlevideo.com`, `ytimg.com`, `ggpht.com`,
`youtubei.googleapis.com`, and `youtube.googleapis.com` in the domain list.

## Build

Requirements: macOS, Xcode command-line tools, and an internet connection for
the pinned sing-box download.

```bash
./Scripts/validate.sh
./Scripts/build-dmg.sh
```

The DMG is written to `dist/`. To build with an already downloaded arm64
sing-box binary:

```bash
MATVEEV_SING_BOX_BINARY=/path/to/sing-box ./Scripts/build-dmg.sh
```

## Release

Push the repository, then create and push a version tag:

```bash
git tag v1.0.2
git push origin main --tags
```

The included GitHub Actions workflow validates the project, builds the DMG and
attaches it to a GitHub Release.

## Security and privacy

Subscription data stays on the Mac and is stored with user-only permissions.
The privileged controller accepts a small fixed command set and validates every
new sing-box configuration before applying it. See [SECURITY.md](SECURITY.md)
for reporting instructions.

## License

GPL-3.0-or-later. The bundled runtime is built from
[SagerNet/sing-box](https://github.com/SagerNet/sing-box); see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
