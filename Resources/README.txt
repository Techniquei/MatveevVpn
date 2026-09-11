matveevVpn 1.2.3 for macOS (Apple Silicon)
========================================

Move matveevVpn to Applications, open it, and choose Install and set up.
Enter an HTTPS VLESS subscription URL or a direct VLESS link, load nodes, choose one, and install.
macOS requests administrator permission to install or repair the system service.
Routine connection and routing changes do not need a password.

Choose Selective to route matching domains/applications, or All Traffic for a
full tunnel. Local destinations remain direct. Domain patterns example.com and
*.example.com both include the base domain and all subdomains.
Add Application includes helpers within that application's bundle.
Fresh installations include editable routes for YouTube, Telegram, ChatGPT,
Claude and Cursor. App updates do not overwrite rules you have already saved.

Settings survive app replacement and reinstalling. Version 1.0 settings are
migrated once from the canonical ~/VPN folder, without scanning backups.
Settings are stored privately in:
~/Library/Application Support/matveevVpn

Change your subscription and node in Connection Settings. Uninstall in the app
removes the system service and moves the app to Trash, preserving user settings.
Reset All Settings explicitly clears saved settings.

Includes sing-box 1.14.0, Xray-core 26.3.27 and Sparkle 2.9.6.
This development build is ad-hoc signed and is not notarized by Apple.
