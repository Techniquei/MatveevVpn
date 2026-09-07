#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT_DIR/.build/sparkle"
if [[ -f "$DEST/.verified-2.9.6" && -d "$DEST/Sparkle.framework" ]]; then exit 0; fi
mkdir -p "$DEST"
curl -fL --retry 3 --connect-timeout 15 --max-time 180 https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz -o "$DEST/archive.tar.xz"
ACTUAL="$(shasum -a 256 "$DEST/archive.tar.xz" | awk '{print $1}')"
[[ "$ACTUAL" == 52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192 ]] || exit 1
tar -xf "$DEST/archive.tar.xz" -C "$DEST"
touch "$DEST/.verified-2.9.6"
