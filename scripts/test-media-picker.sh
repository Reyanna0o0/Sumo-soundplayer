#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$root/.build-support/media-picker-tests"
mkdir -p "$scratch/ModuleCache"
xcrun swiftc -parse-as-library -swift-version 5 \
  -module-cache-path "$scratch/ModuleCache" \
  "$root/SituationVoicePlayer/Sources/Services/MediaPickerSession.swift" \
  "$root/tests/MediaPickerSessionChecks.swift" -o "$scratch/session-checks"
"$scratch/session-checks"
