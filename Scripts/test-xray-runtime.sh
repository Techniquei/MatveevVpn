#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
/bin/bash "$ROOT_DIR/Scripts/build-xray-runtime.sh"
export GOTOOLCHAIN=local
export GOPATH="$ROOT_DIR/.build/go"
export GOCACHE="$ROOT_DIR/.build/go-cache"
export CGO_ENABLED=0
cd "$ROOT_DIR/Runtime"
"$ROOT_DIR/.build/toolchains/go1.27.1/bin/go" test -mod=readonly -timeout 30s ./...
/usr/bin/python3 "$ROOT_DIR/Tests/xray-runtime-process-test.py" \
  "$ROOT_DIR/.build/xray-runtime/matveev-xray-runtime"
