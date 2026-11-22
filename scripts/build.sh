#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-ipa}"
case "$mode" in
  simulator) sdk=iphonesimulator; destination='generic/platform=iOS Simulator' ;;
  device|ipa) sdk=iphoneos; destination='generic/platform=iOS' ;;
  *) echo 'Usage: bash scripts/build.sh [ipa|device|simulator]' >&2; exit 2 ;;
esac
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
python3 "$root/scripts/verify-resources.py"
if [[ ! -s "$root/SituationVoicePlayer/VideoSupport/lib/iphoneos/libsimoavi.a" ||
      ! -s "$root/SituationVoicePlayer/VideoSupport/lib/iphonesimulator/libsimoavi.a" ]]; then
  bash "$root/scripts/prepare.sh"
fi
derived="$root/.build-support/DerivedData-$sdk"
xcodebuild -project "$root/SituationVoicePlayer/SituationVoicePlayer.xcodeproj" \
  -scheme SituationVoicePlayer -configuration Release -sdk "$sdk" \
  -destination "$destination" -derivedDataPath "$derived" \
  -clonedSourcePackagesDirPath "$root/.build-support/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= build
if [[ "$mode" == ipa ]]; then
  python3 "$root/scripts/package-ipa.py" "$derived/Build/Products/Release-iphoneos/SituationVoicePlayer.app"
fi
