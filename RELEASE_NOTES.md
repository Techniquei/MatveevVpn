# matveevVpn 1.4.3-beta.4

Update checks now record detailed Sparkle errors, including underlying network
failures, in exported logs. Manual checks also record the selected update channel.
This improves diagnosis of Update Error; it does not change GitHub availability
or resolve the VPN transport EOF reported on another device.

When VPN DNS responds but the direct DNS check fails, the app shows the VPN
as connected and displays a warning instead of a spinning connection indicator.

Use **Settings → Subscriptions** to add, name, switch or remove VPN
subscriptions. The app remembers the selected server for each subscription and
uses its saved server list when switching. Your existing subscription appears
automatically, and routing rules are shared across subscriptions. Closing the
subscription editor re-enables the subscription controls in Settings.

Removing the active subscription switches to the most recently used remaining
subscription. Removing the last one disconnects the VPN.

Build **1427**, system component **30**. Requires an Apple Silicon Mac running
macOS 13 or later. Available through the opt-in beta update channel.
