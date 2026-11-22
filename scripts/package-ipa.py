#!/usr/bin/env python3
"""Package a device Release .app for later user signing, never for OTA install."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
if len(sys.argv) != 2:
    raise SystemExit("Usage: python3 scripts/package-ipa.py /path/to/device.app")
app = Path(sys.argv[1]).resolve()
with (app / "Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
if info.get("DTPlatformName") != "iphoneos":
    raise SystemExit("Only an iPhoneOS device build can be packaged as an IPA.")
if list(app.rglob("embedded.mobileprovision")) or list(app.rglob("_CodeSignature")):
    raise SystemExit("Expected a fresh unsigned build without profiles or signature directories.")
version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
output = ROOT / "dist"
output.mkdir(exist_ok=True)
ipa = output / f"simo-{version}-build{build}-unsigned.ipa"
with tempfile.TemporaryDirectory(prefix=".simo-ipa-", dir=output) as temporary:
    payload = Path(temporary) / "Payload"
    payload.mkdir()
    subprocess.run(["ditto", "--norsrc", str(app), str(payload / app.name)], check=True)
    # Keep the local build's symbols for debugging, but omit its source-path map from the IPA.
    executable = payload / app.name / info["CFBundleExecutable"]
    subprocess.run(["xcrun", "strip", "-S", str(executable)], check=True)
    # Write a new archive; never append to an older package.
    archive = Path(temporary) / ipa.name
    subprocess.run(["ditto", "-c", "-k", "--norsrc", "--keepParent", str(payload), str(archive)], check=True)
    archive.replace(ipa)
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
(output / (ipa.name + ".sha256")).write_text(f"{digest}  {ipa.name}\n")
commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True)
status = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain"], capture_output=True, text=True)
metadata = {
    "file": ipa.name, "sha256": digest, "bytes": ipa.stat().st_size,
    "version": version, "build": build, "bundleIdentifier": info["CFBundleIdentifier"],
    "minimumOSVersion": info["MinimumOSVersion"], "signed": False,
    "sourceCommit": commit.stdout.strip() if commit.returncode == 0 else None,
    "sourceWorktreeDirty": bool(status.stdout.strip()) if status.returncode == 0 else None,
    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
}
(output / (ipa.name + ".json")).write_text(json.dumps(metadata, indent=2) + "\n")
print(json.dumps(metadata, indent=2))
