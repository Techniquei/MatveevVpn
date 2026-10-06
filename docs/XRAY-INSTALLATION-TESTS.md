# Xray installation verification — 6 October 2026

The ChatGPT conversation “Диагностика DNS MacBook” records launchd rejecting
`com.apple.quarantine` on the installed plist/program and `Bootstrap failed: 5`.
The user reports the same failure after Sparkle and a clean installation.
Native macOS `install` was independently checked: it copies quarantine, even
when `COPYFILE_DISABLE=1` is set. Clearing xattrs before building a DMG cannot
prevent a downloaded app from acquiring quarantine afterward.

## Changes

System component **25** stages and verifies both arm64 binaries, stops the old
service, snapshots its stopped state, replaces the bin directory, clears only
installed quarantine, starts off, and applies the supplied configuration through
IPC. An Apply/bootstrap failure restores the old binaries, configuration,
accepted state, ownership metadata, rules and component version. Xray rollback
waits on IPC; the legacy controller waits on its status file. Source app
quarantine and unrelated xattrs remain intact. Readiness uses one 15-second
monotonic deadline.

The old installer ignored its CONFIG argument and required a legacy config file
even when backing up an Xray installation. Both defects are fixed. The service's
4 KiB `ReadSlice` limitation is replaced with bounded reads up to the advertised
1 MiB request limit. The new installer explicitly checks the off acknowledgement
before returning; Swift requests the desired connection separately.

The current architecture is Swift settings/client → privileged service → worker.
The service owns accepted state, DNS, routes and recovery; the worker owns its
Xray-core instance and TUN. libXray remains necessary for share-link conversion.
Unused standalone sing-box/Xray engines and legacy controller helpers are no
longer shipped or left in the newly installed bin directory. Diagnostics report
Xray and the actual imported protocol.

Signing explicitly covers payload helpers before signing the enclosing app;
Sparkle's original entitlements and identifiers are preserved. See Apple's
[distribution signing guidance](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
and Sparkle's [code signing guidance](https://sparkle-project.org/documentation/sandboxing/#code-signing).

## Verified

| Check | Result |
| --- | --- |
| Pinned Go module verification and Go package tests | Passed |
| Worker EOF, SIGTERM, oversized input and listener cleanup | Passed |
| Real IPC with an 80-node subscription and oversized request rejection | Passed |
| Swift type checking, configuration, persistence, coordinator, first run, diagnostics, layout, updater and service tests | Passed |
| Legacy controller, DNS restoration, routing and lifecycle regressions | Passed |
| Quarantined clean install, failed first start cleanup and retry | Passed |
| Xray repair without the legacy config.json | Passed |
| Intel-only helper rejected before stopping the previous service | Passed |
| Failed Xray upgrade restores state, binaries, version and local readiness | Passed |
| Rejected installation intent restores the previous service | Passed |
| Legacy controller rollback and upgrade to stopped Xray | Passed |
| Ready-made DMG's installer and actual binaries | Passed |
| DMG checksum, deep signature verification, helper signatures and Sparkle entitlements | Passed |
| Sparkle delegate/relaunch checks linked against the packaged framework | Passed |

The original working-directory validation runs were interrupted by Swift reporting
input files modified during compilation, without changes to file contents.
Already completed Go and legacy checks were retained; the remaining Swift,
routing, lifecycle and installer checks passed on an immutable source snapshot.
Release packaging now compiles a temporary source snapshot to avoid the same
working-directory metadata issue during local builds.

The GUI, service and worker are **arm64**, with Mach-O minimum macOS **13.0**.
The DMG is approximately **51 MiB**, versus approximately 90 MiB previously.
The initial verification artifact uses app version 1.4.0-beta.xray/build 1413.
The subsequent release candidate is 1.4.0-beta.xray.1/build 1414, with identical
component fixes and explicit beta-channel routing. Publication uses the normal
tag-triggered validation, signing and release workflow.

Artifact: `.build/quarantine-fix/matveevVpn-1.4.0-beta.xray-arm64.dmg`

SHA-256: `a3ad04fe091bae7ac038b14350bd7d89993366a6583c85c965d9caddd01c05a0`

Logs: `.build/quarantine-validation.log`,
`.build/quarantine-snapshot-validation.log`,
`.build/quarantine-artifact-tests.log`,
`.build/quarantine-packaged-sparkle.log`, `.build/quarantine-build.log`.

## Limits

Installer tests run the actual saved installer, real file copying/xattrs, native
user launchd, the service socket and real worker validation in a disposable
directory. Only fixed system paths, ownership, the root check and launchd domain
are adapted. All configurations stay off, so tests change no system DNS/routes
and create no real TUN. User launchd accepted the quarantined plist on this Mac;
the reported system-daemon quarantine rejection is modeled at the bootstrap
boundary, not claimed as reproduced in that user domain.

A browser-downloaded clean install of the real privileged LaunchDaemon, TUN
connection/stop, and an end-to-end Sparkle install on the other Mac have not been
verified. sudo requires an administrator password here, and the current installed
VPN was not replaced. No Developer ID signing identity is available; the app is
ad-hoc signed and not notarized. Clearing installed component quarantine leaves
the downloaded app's normal Gatekeeper approval as a separate macOS step.
