# matveevVpn 1.4.1

System component installation works on a Mac that does not have Xcode or the
Command Line Tools installed.

The installer ran helper checks through developer-tool stubs. On a Mac without
those tools, macOS tries to show an installation prompt. An administrator
install has no GUI session that can display it, so installation stopped with
“No developer tools were found and no install could be requested.” Those checks
now use the system tools that ship with macOS.

**Upgrade notes:** Build **1421**. System component **28** is unchanged, so an
existing installation is not replaced and macOS does not ask for administrator
authorization again. If installation failed on 1.4.0, relaunch after this update
and approve the prompt once. Subscriptions, the selected server and routing
settings are preserved.

Requires an Apple Silicon Mac running macOS 13 or later. Available through the
standard update channel.
