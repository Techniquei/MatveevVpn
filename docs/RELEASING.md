# Releasing

1. Update app version in VPNController.swift and VERSION/BUILD_NUMBER in build-dmg.sh.
2. Move the Unreleased changelog and release notes into the intended version and
   run Scripts/validate.sh.
3. Build and verify the DMG on a test Mac.
4. Push an explicit matching version tag when ready to publish.

The release workflow verifies the tag, validates, builds the DMG, signs an
appcast and attaches both to GitHub Releases. The app reads the appcast from the
latest release attachment. No release is published merely by building locally.

## Sparkle signing

The public key is committed in Resources/sparkle-public-key.txt. The private key
is stored in macOS Keychain under the Sparkle account `matveevVpn`, and the GitHub
repository secret `SPARKLE_PRIVATE_KEY` is configured. Never put the private key
in the repository, a command argument, a diagnostic report or build output.

For a local signed feed, pass a directory containing only the intended DMG:

```sh
bash Scripts/sign-release.sh .build/release-1.3.5 1.3.5
```

The build supports CODE_SIGN_IDENTITY. Current local builds are ad-hoc signed;
no Developer ID certificate was available during development. Production
notarization requires an Apple Developer account and credentials. Keep the same
Sparkle public key in later releases so installed apps can verify updates.

Before relying on automatic updates, test an installed 1.1 build against a newer
signed test update and verify persistence. Version 1.0 has no updater and must
be upgraded manually once. A local signed appcast alone does not prove that the
end-to-end UI installation and relaunch work on every supported macOS version.
For the domain-only routing change, verify that an upgrade preserves custom
domains and that removed application/path fields do not produce runtime rules.

## Stable and beta releases

Stable tags use `vX.Y.Z`; beta tags use `vX.Y.Z-beta.N`. VERSION must match the
full tag suffix, and BUILD_NUMBER must increase across both channels. For example,
1.3.5 uses 1305 and 1.4.0-beta.1 uses 1400; the eventual stable 1.4.0 must use a
number greater than all of its beta builds.

The workflow preserves the latest stable appcast before generating the new item.
`sign-release.sh DIR VERSION beta` passes Sparkle's `--channel beta`. A beta is
published as a prerelease without changing GitHub's latest stable release. Its
combined appcast is then uploaded to the latest stable release's appcast asset.
Clients with beta disabled ignore beta items, including during manual checks.
Do not publish the redesign on the default channel until it is accepted for all
users. The 1.3.5 opt-in release retains the 1.3.4 UI and system payload.

Verify both default-channel and beta-channel update discovery against the signed
feed before publication. Signed archive verification is required; local test apps
must never be installed over the user's current VPN during these checks.

For either a stable release or a combined feed containing a beta, run:

```sh
bash Scripts/test-update-feed.sh .build/release-1.4.0-beta.1/appcast.xml
```

This probes Sparkle from build 1305 (1.3.5) against a loopback-only feed using
disposable bundles with beta off, on, then off. It never downloads or installs
an update. Both stable and beta release workflows run this check before
publication. Stable clients must be offered only the default-channel build;
beta clients also receive a newer stable build when available.

For 1.4.0 stable, use a build number greater than 1418 (the beta.5 build), retain
the existing signing key and publish the item without a beta channel. The
application update preserves settings and automatically updates system component
12 to 27 on launch, with administrator authorization. Check cancellation/failure
followed by relaunch: a new attempt must start without a separate Update button.
