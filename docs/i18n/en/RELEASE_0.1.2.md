# Sumo v0.1.2 · build 35

[简体中文](../../RELEASE_0.1.2.md) · [繁體中文](../zh-Hant/RELEASE_0.1.2.md) · **English** · [日本語](../ja/RELEASE_0.1.2.md) · [한국어](../ko/RELEASE_0.1.2.md)

**Stable release.** This version adds creator avatar cropping and includes the photo picker stability fixes.

## Download and update

**[Download build 35 IPA](https://github.com/Reyanna0o0/Sumo-soundplayer/releases/download/v0.1.2/simo-0.1.2-build35-unsigned.ipa)**

Requires **iOS / iPadOS 18 or later**.

1. Open the link on your computer and find the completed IPA in Downloads.
2. For a first installation, follow the [installation guide](INSTALL.md). To update, use your original signing method and install over the existing app. **Do not uninstall first.**

**Already using build 35? No reinstall is needed.** The stable release uses the same IPA as the preview, with no additional app or database changes. [Download help](DOWNLOAD.md)

## Creator avatar cropping

- Choosing an avatar from Photos or Files in the creator editor now opens **Crop avatar**.
- Drag to position the image, and pinch or use the slider to zoom. A circular frame previews the avatar. Reset returns to the initial centered view.
- Choose **Use**, then save the creator. Canceling the crop keeps the current avatar; canceling the entire editor discards the current edits.
- Creator covers or call avatars that inherit this avatar use the selected region. Work covers retain their existing 4:3 crop.

## Verification

- Full device and simulator Release builds, resource checks and five-language app resources passed verification.
- Simulator UI checks covered photo selection, crop cancellation, dragging, pinch and slider zoom, reset, saving, repeated replacement and canceling the editor. App-hosted checks confirmed the selected image region, square output, 4:3 cover compatibility, inherited avatars and draft cleanup.
- Testing used an isolated simulator and synthetic media, without operating the user's phone. The Files entry shares this crop flow, but browsing in the system file picker through to cropping has not been verified end to end. Older photos, iCloud downloads, third-party file services and iPad layouts still need device checks.
- The 3,755 core checks and 9 picker-session checks were completed for build 34. Build 35 did not change the core or database schema; its additional checks focused on avatar cropping. [Detailed verification record — Simplified Chinese](../../RELEASE_STATUS.md)

## Included files

For installation, download the `.ipa` and sign it. The `.ipa.json` and `.ipa.sha256` files record build provenance and checksum. `simo-0.1.2-build35-source.zip` contains corresponding source, third-party source materials and rebuilding instructions. `LICENSE.txt` and `SHA256SUMS.txt` provide the license and asset checksums. Previously published build 33 and 34 assets remain available.

[Report a problem](https://github.com/Reyanna0o0/Sumo-soundplayer/issues/new?template=bug-report.yml) · [License](../../../LICENSE)
