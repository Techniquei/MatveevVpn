matveevVpn for macOS (Apple Silicon)
==================================

Move matveevVpn to Applications and open it. First-run setup installs the
system component, then asks for an HTTPS subscription URL or a direct VLESS link.
Choose Connect; the app loads the subscription and selects the first server.
macOS requests administrator permission to install or repair the system service.
After an app update, an outdated component is updated automatically at launch.
If authorization is cancelled or installation fails, relaunch the app to retry.
Routine connection and routing changes do not need a password.

Choose Selective to route selected service presets and matching custom domains, or
All Traffic for a full tunnel. Local destinations remain direct. Domain patterns
example.com and *.example.com both include the base domain and all subdomains.
Enter one domain per line in Routing > Custom rules > Domains, then Save and Apply.
Preset rules are downloaded from MetaCubeX through the VPN, cached and refreshed daily.
Optional DNS-level ad blocking uses HaGeZi Multi PRO mini, starts from a bundled
copy and refreshes the validated list through the VPN every eight hours. It
cannot remove ads served from the same domain as video content.

Settings survive app replacement and reinstalling. Version 1.0 settings are
migrated once from the canonical ~/VPN folder, without scanning backups.
Settings are stored privately in:
~/Library/Application Support/matveevVpn

Change your subscription in Settings and choose a server in the main window. Uninstall in the app
removes the system service and moves the app to Trash, preserving user settings.
Reset All Settings explicitly clears saved settings.

Includes sing-box 1.14.0, Xray-core 26.3.27 and Sparkle 2.9.6.
This development build is ad-hoc signed and is not notarized by Apple.
