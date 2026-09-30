# matveevVpn 1.4.0-beta.1

This is an opt-in beta release. Enable **Receive beta updates** in version 1.3.5
or install this beta DMG manually. Stable-only users keep the familiar interface.

- Redesigned main screen with a full-width server list, the active server pinned
  first, click-to-connect server rows, bottom icon actions and hover feedback.
- Consistent compact styling for Subscription, Settings and Routing windows;
  auxiliary windows are movable and Compatibility opens from its entire header.
- First launch installs the stopped component before requesting a subscription,
  shows progress during authorization and selects the first server automatically.
- Displays the most recent successful automatic routing data refresh.
- Adds the beta update preference, disabled by default on new installations.
- Removes obsolete node-picker state and fixes latency summary counts.

For existing installations, **Settings → Repair service…** installs the updated
system scripts needed to publish the routing refresh date. The app update alone
does not replace the component because its protocol is unchanged. Repair may
briefly interrupt the connection. Existing subscriptions and routing rules remain.

Requires Apple Silicon and macOS 13 or later. The current build is ad-hoc signed
and is not notarized by Apple.
