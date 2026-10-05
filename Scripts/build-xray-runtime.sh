#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GO_VERSION="1.27.1"
GO_ARCHIVE_SHA256="ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12"
GO_DIR="$ROOT_DIR/.build/toolchains/go$GO_VERSION"
GO_BINARY="$GO_DIR/bin/go"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "The prototype currently targets macOS arm64." >&2
  exit 1
fi

if [[ ! -x "$GO_BINARY" ]]; then
  mkdir -p "$ROOT_DIR/.build/toolchains"
  STAGE="$(mktemp -d "$ROOT_DIR/.build/toolchains/download.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  curl -fsSL --connect-timeout 10 --max-time 180 \
    "https://go.dev/dl/go$GO_VERSION.darwin-arm64.tar.gz" -o "$STAGE/go.tar.gz"
  printf '%s  %s\n' "$GO_ARCHIVE_SHA256" "$STAGE/go.tar.gz" | shasum -a 256 -c -
  tar -xzf "$STAGE/go.tar.gz" -C "$STAGE"
  mv "$STAGE/go" "$GO_DIR"
fi
[[ "$("$GO_BINARY" version)" == "go version go$GO_VERSION darwin/arm64" ]]

export GOTOOLCHAIN=local
export GOPATH="$ROOT_DIR/.build/go"
export GOCACHE="$ROOT_DIR/.build/go-cache"
export CGO_ENABLED=0
mkdir -p "$ROOT_DIR/.build/xray-runtime"
cd "$ROOT_DIR/Runtime"
"$GO_BINARY" build -mod=readonly -trimpath -o "$ROOT_DIR/.build/xray-runtime/matveev-xray-runtime" .
"$GO_BINARY" mod verify
echo "runtime: .build/xray-runtime/matveev-xray-runtime"
