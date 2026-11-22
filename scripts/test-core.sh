#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$root/.build-support/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
cd "$root/hibiki"
swift run --disable-sandbox --cache-path ./.swiftcache --scratch-path ./.build SelfTest
