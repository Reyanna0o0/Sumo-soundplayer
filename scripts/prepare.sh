#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$root/scripts/verify-resources.py"
bash "$root/SituationVoicePlayer/VideoSupport/build.sh" "$root/.build-support/ffmpeg"
