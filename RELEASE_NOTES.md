# matveevVpn 1.1.12

- Stops stalled subscription downloads and VPN controller requests after 10 seconds.
- Shows a copyable, privacy-redacted error report when loading or connecting fails.
- Accepts direct VLESS links, URL-safe Base64 and mixed subscription lists.
- Fixes the clipped Settings and Diagnostics button at the bottom of the window.
- Makes the main, Settings and supporting windows more compact in both dimensions.
- Places one combined download/upload traffic graph inside the current-node card.
- Uses balanced action rows on the main screen and in node selection.
- Lets you switch nodes directly from the main screen without opening another window.
- Places VPN mode beside the On/Off status and moves Uninstall to Settings.
- Removes the redundant Done status from the main screen.
- Keeps the window size stable while an operation is in progress.
- Uses a four-icon action toolbar and displays progress inside the On/Off badge.
- Uses a compact Routing switch for selective versus all-traffic mode.
- Makes the main window more square and uses evenly spaced square action buttons.
- Adds hover highlighting and tooltips to the main action buttons.
- Shows connection state and progress directly in the power button instead of a separate badge.
- Groups the action buttons into a compact dock with consistent spacing.
- Narrows the main window to a compact 420-point layout.
- Highlights the power button in blue only while connected.
- Visually dims the traffic card while the VPN is disconnected.
- Loads legacy subscriptions safely when their old routing-rules file is missing.

Settings, subscription, selected node, mode and routing rules are preserved when
updating from 1.1.11.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
