# Third-party notices

The worker links Xray-core 26.9.30 (commit b26a91de4f32), licensed under
MPL-2.0. libXray v1.260930.0 supplies share-link conversion under MIT.
Both exact module versions and their dependencies are pinned in `Runtime/go.mod`
and verified with `Runtime/go.sum`. Their licenses are bundled as
`xray-core-LICENSE` and `libxray-LICENSE`.

- https://github.com/XTLS/Xray-core/tree/b26a91de4f32
- https://github.com/XTLS/libXray/tree/v1.260930.0

The Xray beta no longer distributes the legacy sing-box or standalone Xray CLI
binaries. Legacy controller sources remain in the repository for regression
checks and migration documentation.

Sparkle 2.9.6 is distributed under its permissive license and bundled notices.
The build pins its archive SHA-256 in `Scripts/fetch-sparkle.sh` and includes
Sparkle-LICENSE in the application's resources.

- https://github.com/sparkle-project/Sparkle
- https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6

Service presets include normalized data from MetaCubeX/meta-rules-dat. The
repository is licensed under GPL-3.0 and incorporates data from the upstream
projects listed in its notices.

- https://github.com/MetaCubeX/meta-rules-dat

Advertising blocking uses HaGeZi Multi PRO mini from the HaGeZi DNS Blocklists
repository. The pinned initial list and its GPL-3.0 license are bundled as
`Hagezi-LICENSE`; updates are fetched directly from the official repository.

- https://github.com/hagezi/dns-blocklists
