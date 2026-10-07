# matveevVpn 1.4.0-beta.5

Automatic component updates and simpler routing settings.

- Outdated system components now update automatically when the app launches.
  macOS requests administrator authorization. If installation fails or is
  cancelled, the app retries on the next launch.
- Shows installation progress and removes the separate component Update button.
- Keeps your subscription, selected server, routing mode, service presets and
  custom domains during upgrades.
- Adds **Change server** beside **Servers** in the main window.
- Simplifies **Custom rules** to a single **Domains** editor. Enter one domain
  per line; `example.com` and `*.example.com` include the base domain and its
  subdomains.
- Removes rules import/export and the routing-rule inspector from Settings.
- Fixes Disconnect and Reset compatibility with older system components before
  they are updated, and preserves customized legacy domain lists.

**Upgrade notes:** Application-name and executable-path rules are no longer
applied. In Selective mode, use domains or service presets to route the required
traffic through the VPN, or choose All Traffic. Existing custom domains remain
available.

Uses system component **27**, sing-box for TUN/DNS/routing and Xray-core for
REALITY/XHTTP. Requires an Apple Silicon Mac running macOS 13 or later.

Available through the opt-in beta update channel. The latest stable release
remains **1.3.5**.
