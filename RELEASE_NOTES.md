# matveevVpn 1.2.0

- Stops stalled subscription downloads and VPN controller requests after 10 seconds.
- Shows a copyable, privacy-redacted error report when loading or connecting fails.
- Accepts direct VLESS links, URL-safe Base64 and mixed subscription lists.
- Redesigns the main window as a compact 420-point layout with balanced spacing.
- Lets you switch nodes directly from a stable-width picker on the main screen.
- Places a compact combined traffic graph inside the current-node card.
- Keeps independent download and upload readouts stable as their values and units change.
- Uses a four-icon action dock with hover feedback, tooltips and in-button progress.
- Highlights the power button only while connected and dims the traffic card while disconnected.
- Replaces the old VPN mode control with a compact Routing switch.
- Moves Uninstall into Settings and fixes clipped or oversized controls throughout the app.
- Keeps the window size stable while operations and errors are displayed.
- Loads legacy subscriptions safely when their old routing-rules file is missing.

Settings, subscription, selected node, mode and routing rules are preserved when
updating from 1.1.11.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
