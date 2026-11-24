#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$root/.build-support/speaker-protection-tests"
mkdir -p "$scratch/ModuleCache"
xcrun swiftc -parse-as-library -swift-version 5 \
  -module-cache-path "$scratch/ModuleCache" \
  "$root/SituationVoicePlayer/Sources/Services/SpeakerProtectionPolicy.swift" \
  "$root/tests/SpeakerProtectionChecks.swift" -o "$scratch/speaker-protection-checks"
"$scratch/speaker-protection-checks"
