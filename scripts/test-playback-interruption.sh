#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$root/.build-support/playback-interruption-tests"
mkdir -p "$scratch/ModuleCache"
xcrun swiftc -parse-as-library -swift-version 5 \
  -module-cache-path "$scratch/ModuleCache" \
  "$root/SituationVoicePlayer/Sources/Services/PlaybackInterruptionState.swift" \
  "$root/SituationVoicePlayer/Sources/Services/AudioRemoteCommandGate.swift" \
  "$root/tests/PlaybackInterruptionChecks.swift" -o "$scratch/interruption-checks"
"$scratch/interruption-checks"
