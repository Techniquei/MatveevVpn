# Releasing

1. Update app version in VPNController.swift and VERSION/BUILD_NUMBER in build-dmg.sh.
2. Update release notes and run Scripts/validate.sh.
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
bash Scripts/sign-release.sh .build/release-1.1 1.1.0
```

The build supports CODE_SIGN_IDENTITY. Current local builds are ad-hoc signed;
no Developer ID certificate was available during development. Production
notarization requires an Apple Developer account and credentials. Keep the same
Sparkle public key in later releases so installed apps can verify updates.

Before relying on automatic updates, test an installed 1.1 build against a newer
signed test update and verify persistence. Version 1.0 has no updater and must
be upgraded manually once. A local signed appcast alone does not prove that the
end-to-end UI installation and relaunch work on every supported macOS version.
