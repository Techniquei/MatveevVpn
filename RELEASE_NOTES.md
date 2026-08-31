# matveevVpn 1.0.2

Traffic peaks now have vertical edges, and upload traffic is shown as a clear
pink line matching its live speed label.

## 1.0.1

This patch documents manual YouTube domain rules, refreshes the app automatically
after Terminal setup, and fixes first-run startup on Macs where launchd or
sing-box needs more than three seconds to become ready.

## 1.0.0

The first public release of the universal selective-routing client for Apple
Silicon Macs.

After the one-time setup, normal VPN controls and routing configuration changes
do not ask for an administrator password. Routing rules can be edited directly
in the native app, and the traffic card shows stable download and upload rates
over the most recent 60 seconds.

## Requirements

- Apple Silicon Mac
- macOS 13 or newer
- VLESS subscription URL

This release is ad-hoc signed and not notarized. On first launch, right-click the
application and choose **Open** if macOS displays a Gatekeeper warning.
