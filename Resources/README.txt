matveevVpn 1.4.0-beta.xray.1 for macOS (Apple Silicon)
================================================

Move matveevVpn to Applications and open it. macOS requests administrator
permission to install the system service. Installation starts with the VPN off.
Add an HTTPS subscription URL or a supported direct link and choose a server.
Routine connection and routing changes do not need a password.

Existing installations need system component version 25. Choose Update on the
main screen or Settings → Repair service. This fixes downloaded/quarantined
component files and retains user settings. Installation validates and accepts
the configuration before connecting; a local startup failure restores the old
component and its accepted state.

Choose Selective for selected service presets and custom domains, or All Traffic
for a full tunnel. Local destinations remain direct. Domain patterns example.com
and *.example.com include the base domain and its subdomains. Optional DNS ad
blocking uses HaGeZi Multi PRO mini and cannot remove ads served from the same
domain as video content.

Settings survive app replacement and reinstalling and are stored privately in:
~/Library/Application Support/matveevVpn

Change the subscription from Change next to Servers. In-app Uninstall removes
the system service and moves the app to Trash, preserving user settings.
Reset All Settings explicitly clears saved settings.

Includes Xray-core 26.9.30, libXray share-link conversion and Sparkle 2.9.6.
Requires Apple Silicon and macOS 13 or later. This development build is ad-hoc
signed and is not notarized by Apple. Installing the component clears quarantine
only on installed component copies; the downloaded application's Gatekeeper
approval remains a separate macOS step.
