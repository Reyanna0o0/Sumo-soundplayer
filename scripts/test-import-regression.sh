#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$root/.build-support/import-regression/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
cd "$root/tests/ImportRegression"
swift run --disable-sandbox --cache-path "$root/.build-support/import-regression/cache" --scratch-path "$root/.build-support/import-regression/build" CoreRegression
swift run --skip-build --disable-sandbox --cache-path "$root/.build-support/import-regression/cache" --scratch-path "$root/.build-support/import-regression/build" CoreRegression --risk-probes
