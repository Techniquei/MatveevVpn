# matveevVpn 1.1.0

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
