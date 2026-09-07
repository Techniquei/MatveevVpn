#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVES="${1:?Pass the directory containing only the release DMG}"
VERSION="${2:?Pass the release version}"
/bin/bash "$ROOT_DIR/Scripts/fetch-sparkle.sh"
ARGS=(--download-url-prefix "https://github.com/Techniquei/MatveevVpn/releases/download/v$VERSION/" --maximum-deltas 0)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$ROOT_DIR/.build/sparkle/bin/generate_appcast" --ed-key-file - "${ARGS[@]}" "$ARCHIVES"
else
  "$ROOT_DIR/.build/sparkle/bin/generate_appcast" --account matveevVpn "${ARGS[@]}" "$ARCHIVES"
fi
test -s "$ARCHIVES/appcast.xml"
