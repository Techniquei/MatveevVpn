# matveevVpn 1.1.1

- Fixed a regression where networks that block external UDP DNS could leave the
  tunnel running while routed sites failed to open.
- VPN node hostnames now bootstrap through the macOS system resolver, as in the
  working 1.0 configuration.
- Diagnostics now force their dedicated IPv4/IPv6 endpoints through the VPN,
  including in Selective mode, instead of displaying the normal direct egress.

This update keeps the 1.1 settings, selected node, mode and routing rules.
The system controller remains version 2, so no administrator password is needed
to apply the corrected configuration. The app compares the installed config and
applies the fix automatically on its first launch.

## Included in 1.1

- Settings, subscription and selected node survive reinstalling the app.
- Initial setup and subscription changes are fully native; Terminal setup is removed.
- Switch between Selective and All Traffic without losing your rules.
- Route domains with example.com / *.example.com and add application bundles,
  including their internal helpers.
- Configuration changes are validated and committed with rollback and recovery.
- Menu bar controls and traffic rates, launch at login and optional failure alerts.
- Connection diagnostics, node reachability checks and rule explanations.
- Export/import routing rules without subscription credentials.
- Signed Sparkle automatic updates and Check for Updates.

Existing 1.0 users install this release manually once. Settings are migrated
from the canonical ~/VPN folder; backup folders are not searched.

Requires Apple Silicon, macOS 13+ and an HTTPS VLESS subscription URL.
System-component installation or repair needs administrator permission.
Routine connection/configuration changes do not.

Full mode includes IPv4/IPv6 and VPN DNS while keeping local destinations direct.
It is not a kill switch. Application rules cover executables within the selected
bundle; external shells/runtimes need their own rules.

The current build is ad-hoc signed and is not notarized by Apple.
