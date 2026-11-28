#!/usr/bin/env python3
"""Verify the bundled upstream sources, model and license copies."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
expected = {
    "ThirdParty/FFmpeg/ffmpeg-n8.0.1.tar.gz": "679aa13a19415d5ddab91e580084e3ab20c963c8240001e5cbb955a97bdd81b1",
}
model = "SituationVoicePlayer/Sources/Resources/DepthAnythingV2SmallF16.mlpackage/"
expected.update({model + name: digest for name, digest in {
    "Manifest.json": "2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7",
    "Data/com.apple.CoreML/model.mlmodel": "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042",
    "Data/com.apple.CoreML/weights/weight.bin": "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed",
}.items()})
provenance = json.loads((ROOT / "ThirdParty/Lame/provenance.json").read_text())
expected.update({"ThirdParty/Lame/" + name: digest
                 for name, digest in provenance["sourceFiles"].items()})
smb = json.loads((ROOT / "Prototypes/Vendor/AMSMB2/SUMO_SOURCE_FILES.json").read_text())
expected.update({"Prototypes/Vendor/AMSMB2/" + name: digest for name, digest in smb["sha256"].items()})
errors = []
for name, digest in expected.items():
    path = ROOT / name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        errors.append("Missing or changed upstream material: " + name)
for upstream, bundled in [
    ("ThirdParty/Lame/lame-4.0/COPYING", "LAME-COPYING.txt"),
    ("Prototypes/Vendor/AMSMB2/LICENSE", "AMSMB2-LICENSE.txt"),
    ("Prototypes/Vendor/AMSMB2/Dependencies/libsmb2/COPYING", "libsmb2-COPYING.txt"),
    ("ThirdParty/DepthAnythingV2/LICENSE", "DepthAnything-LICENSE.txt"),
    ("SituationVoicePlayer/VideoSupport/LICENSE-FFmpeg.txt", "FFmpeg-LICENSE.txt"),
]:
    copy = ROOT / "SituationVoicePlayer/Sources/Resources" / bundled
    if not copy.is_file() or (ROOT / upstream).read_bytes() != copy.read_bytes():
        errors.append("License copy mismatch: " + bundled)
lock = ROOT / "SituationVoicePlayer/SituationVoicePlayer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
pins = json.loads(lock.read_text())["pins"]
if len(pins) != 1 or pins[0]["identity"] != "zipfoundation" or pins[0]["state"] != {
    "revision": "22787ffb59de99e5dc1fbfe80b19c97a904ad48d", "version": "0.9.20"
}:
    errors.append("Unexpected ZIPFoundation dependency lock")
if errors:
    raise SystemExit("\n".join(errors))
print(f"Verified {len(expected)} upstream files, 5 license copies and ZIPFoundation lock.")
