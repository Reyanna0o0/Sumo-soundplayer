#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$root/.build-support/network-playback-tests"
mkdir -p "$scratch/ModuleCache"
xcrun swiftc -parse-as-library -swift-version 5 \
  -module-cache-path "$scratch/ModuleCache" \
  "$root/SituationVoicePlayer/Sources/Services/NetworkPlaybackEvidence.swift" \
  "$root/SituationVoicePlayer/Sources/Services/NetworkByteRangePlan.swift" \
  "$root/tests/NetworkPlaybackPolicyChecks.swift" -o "$scratch/network-playback-checks"
"$scratch/network-playback-checks"
