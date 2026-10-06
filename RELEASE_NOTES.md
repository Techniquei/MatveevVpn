# matveevVpn 1.4.0-beta.xray.1

This opt-in Xray beta fixes system-component installation after a downloaded app
or Sparkle update carries macOS quarantine attributes. Stable-only users remain
on 1.3.5.

- Clears quarantine only on installed system-component copies before launchd
  bootstrap and rollback. The downloaded app and unrelated attributes are preserved.
- Validates and applies the initial configuration while the VPN is off. Failed
  startup or rejected configuration restores the previous service and accepted state.
- Repairs Xray installations without requiring a legacy configuration file.
- Accepts large subscription requests up to the full 1 MiB IPC limit.
- Explicitly signs the service and worker and verifies arm64 architecture. Removes
  unused legacy engine binaries, reducing the download from about 90 MiB to 51 MiB.

**After updating the app, click Update on the main screen or Settings → Repair
service… and approve the administrator prompt. System component version 25 is
required.** Updating the app alone does not replace the privileged service.
Subscription, selected server and routing settings are retained.

The runtime uses Xray-core 26.9.30 for VLESS, VMess AEAD, Trojan, Shadowsocks,
SOCKS and Hysteria2. Existing direct-egress and server-latency improvements are
included. Legacy VMess QR links, Clash documents and raw Xray JSON are not nodes.

Requires Apple Silicon and macOS 13 or later. This build is ad-hoc signed and is
not notarized by Apple. Native installation regression tests passed in an isolated
user launchd environment; a fresh privileged installation/TUN connection and
end-to-end Sparkle install on a separate Mac have not been verified.
