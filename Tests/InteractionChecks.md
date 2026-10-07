# Native interaction regression checks

Build with `bash Scripts/preview-interactions.sh`, then open the printed app path.
The preview uses the actual views/controller with `FirstRunBoundaryFakes.swift`;
it never executes system commands, installs a component or contacts servers.
Its subscription state is synthetic and its bundle ID differs from the VPN app.
Use the Preview toolbar menu to open the other windows.
Hover the login and notification controls without activating them: those macOS
permission APIs remain native. Do not invoke destructive actions or file exports.

## Compatibility on first launch

1. In the empty Subscription window, click the word Compatibility.
   The Happ switch and explanation must appear.
2. Click the empty right-hand part of the same header. Content must collapse.
3. Repeat with the arrow. Each click must toggle exactly once.
4. Hover the header: its background and outline must highlight.
5. Toggling the Happ switch must not collapse the section.

The old standard macOS disclosure fails steps 1 and 2; only the arrow opens it.
Verified with computer use on 2026-09-30: both clicks fail with the old disclosure
and toggle successfully with `AppDisclosureStyle`. The hover outline is visible.

## Hover coverage

Check buttons, toggles, the server picker, subscription fields and the domain
editor in Subscription, Settings and Routing; also the mode switch, server
rows and actions in Main. Enabled controls must highlight on entry and restore
their appearance on exit. Disabled controls must not highlight or act. Keyboard
focus and activation remain native. System menus/dialogs use macOS highlighting.
Do not run destructive actions or service/network checks in the installed app.

## Custom domains

1. Open Routing. Custom rules must show a single full-width Domains editor.
2. Enter `example.com` and `*.example.org` on separate lines in the fake preview.
3. Save and Apply, reopen Routing and confirm both entries were saved.
4. Edit the draft, choose Revert Changes and confirm the saved domains return.
5. Clear Custom, confirm, then Save and Apply. Preset and ad-blocking choices
   must remain unchanged.

## Background service connection

- Open the app while the service reports starting, recovering, waiting for network,
  waiting for either DNS path, or waiting to retry. Show a spinner and the specific
  state even though no foreground operation is busy.
- During background waiting, Disconnect must stay enabled; using it hides the
  spinner and stops future attempts.
- After a failed manual Connect, keep showing background retry progress. When the
  service later becomes ready, remove the connection error and spinner. Preserve
  unrelated settings errors.
- The menu bar status and power-button accessibility value must use the same
  connection-state text. Long DNS waiting labels must wrap within the 320-point
  main window.
