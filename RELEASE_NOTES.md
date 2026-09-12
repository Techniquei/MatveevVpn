# matveevVpn 1.3.0

- Promotes the source-based HaGeZi Multi PRO mini ad-blocking implementation
  to the 1.3.0 release, with a pinned bundled fallback and validated refreshes
  through the VPN every eight hours.
- Preserves selectable service presets, custom routing and both sing-box and
  Xray transport modes.

# matveevVpn 1.2.7

- Replaces the narrower advertising category with the official HaGeZi Multi PRO
  mini list, which includes VideoRoll and broad regional advertising coverage.
- Bundles a pinned, checksum-verified copy for first use, then validates and
  refreshes the list directly from HaGeZi through the VPN every eight hours.

- Fixes intermittent loss of browsing in Selective mode when the direct DHCP
  resolver tried to rediscover DNS after macOS had switched to the tunnel DNS.
- Uses a numeric direct DNS-over-HTTPS resolver for direct sites and VPN-node
  bootstrap, avoiding the circular lookup seen in runtime logs.
- Adds the app version to startup log entries for clearer diagnostics.

- Adds visible checkboxes for YouTube, Telegram, WhatsApp, Instagram, Facebook,
  X, Discord, ChatGPT, Claude, Gemini, Cursor, GitHub Copilot and Spotify.
- Enables all service presets by default while preserving the existing custom
  domain, application and executable-path controls.
- Adds an optional advertising and tracker blocker. Domain rules are supplied by
  MetaCubeX, downloaded through the VPN, cached and refreshed daily.
- Removes the old hidden routing defaults when they have not been customized.

Settings, subscription, selected node, mode and routing rules are preserved when
updating from 1.2.4 through 1.2.6. Existing custom routing rules remain available.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
