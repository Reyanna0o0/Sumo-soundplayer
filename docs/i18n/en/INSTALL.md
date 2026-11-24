# Install, renew and update

[简体中文](../../INSTALL.md) · [繁體中文](../zh-Hant/INSTALL.md) · **English** · [日本語](../ja/INSTALL.md) · [한국어](../ko/INSTALL.md)

**[Download the IPA · v0.1.4 (build 37)](https://github.com/Reyanna0o0/Sumo-soundplayer/releases/download/v0.1.4/simo-0.1.4-build37-unsigned.ipa)** · [Download help](DOWNLOAD.md)

This is **v0.1.4 / build 37**, a separate new version with speaker protection enabled by default and revised background resumption. It does not replace the same-named build 36 files. Install over the existing app with the same Apple Account, signing settings and app identifier; **do not uninstall first**. [Release notes — Simplified Chinese](../../RELEASE_BUILD37.md)

For a first installation, start below. If the app is already installed, see [Updating without removing your data](#update).

Mac installation with Sideloadly and updating to build 33 have been tested. Windows, AltStore and signature renewal remain unverified. See the [release notes](../../RELEASE_BUILD37.md) and [detailed verification record — Simplified Chinese](../../RELEASE_STATUS.md).

## Before you start

- An iPhone or iPad running iOS / iPadOS 18 or later, a Windows PC or Mac, and a cable for the first connection.
- Your own Apple Account and the downloaded `.ipa` file.

With a free Apple Account, development signatures normally last 7 days, and a device normally supports up to 3 apps installed this way. App ID and other limits also apply; follow the messages from Apple and your signing tool. Renew the signature when needed while keeping the app installed. [Apple account information](https://developer.apple.com/help/account/basics/about-your-developer-account/) · [Sideloadly FAQ](https://sideloadly.io/faq.html)

You sign in to your Apple Account in the signing tool. Sumo itself does not require that login or collect your password, verification codes or signing certificates.

<a id="sideloadly"></a>
## Option 1: Sideloadly on Windows or Mac

1. Download the correct version from the [official Sideloadly website](https://sideloadly.io/index.html). Follow its current instructions for Apple drivers and iTunes / iCloud components on Windows, or preparation on your version of macOS. Avoid mixing components that its website identifies as incompatible.
2. Connect your device with a cable, unlock it and choose **Trust This Computer**. Select the device in Sideloadly.
3. Drag the IPA into Sideloadly and enter your Apple Account. For the first installation, keep the normal settings without adding plugins or changing the app identifier.
4. Click **Start**, complete the account verification prompts, and wait for signing and installation to finish.
5. If prompted about an untrusted developer, trust your account in **Settings → General → VPN & Device Management**. If Developer Mode is required, enable it in **Settings → Privacy & Security → Developer Mode**, then restart and confirm as prompted. [Apple's Developer Mode guide](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
6. Open Sumo. Use an audio file you can obtain again to check importing, playback, background playback and reopening before adding your main collection.

Menu names may vary with the tool and system version. Follow the current official instructions if they differ.

### Renewing the signature

Keep the same Apple Account, app identifier and signing settings. Before expiry, sign the IPA again and install over the existing app. Automatic renewal requires Sideloadly Daemon to be running on your computer and the device to be discoverable over USB or a configured shared Wi-Fi network. Renewal cannot rely on a computer that is switched off. [Automatic renewal details](https://sideloadly.io/faq.html)

## Option 2: AltStore Classic

Follow the official [Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) or [Mac](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) instructions to install AltServer, then AltStore Classic on your device. These instructions refer to the Classic self-signing route.

Download the IPA on the device, open **My Apps** in AltStore and use **+** to select and sign it. For renewal, keep AltServer running and reachable from your device; use **Refresh All** if needed. AltStore itself occupies one app slot with a free account. [AltStore usage guide](https://faq.altstore.io/altstore-classic/your-altstore)

<a id="update"></a>
## Updating without removing your data

On 23 November 2026, the user confirmed that updating to build 33 succeeded and previously imported data remained. This applies to that tested installation; renewal and other environments have not been verified.

Download the new IPA and install over the existing app using **the same Apple Account, signing tool and app identifier**. **Do not uninstall first.** A matching identifier is necessary for an update, but you should still confirm that your own setup retains data. [Sideloadly update guidance](https://sideloadly.io/faq.html)

- If signing expires or installation fails, keep the app installed and check the error, account limits and connection.
- Changing the account, team or app identifier may create a separate app or prevent an update. Data does not necessarily transfer automatically.
- Keep original audio, video and subtitles separately. Export important clips as MP3 / WAV. One-step full-library backup and restore has not been verified.
- Folder imports depend on their original location. If files move, use the work's folder relinking action; reinstalling does not replace relinking.

## Common problems

| Problem | Next step |
| --- | --- |
| Safari downloads the IPA but cannot install it | Give the IPA to the signing tool described above |
| The app stops opening after a few days | Check signature expiry; keep the app and renew with the original account |
| Device or App ID limits appear | Follow the signing tool's message; wait for limits to reset or review installed test apps |
| Your computer cannot see the device | Connect by cable, unlock and trust the computer, and check the Apple drivers |
| Two copies of Sumo appear after updating | Check for a different account or app identifier; preserve the original app and its data |
| Developer Mode is missing | Follow Apple's connection and development-signing steps, then check again; record the system version and message |

<a id="verify"></a>
## Optional: verify the downloaded file

Download the matching `.ipa.sha256` from the same release and place it beside the IPA. Open Terminal or PowerShell in that folder. These commands use build 37; substitute the actual filename for another version.

Mac:

```bash
shasum -a 256 -c simo-0.1.4-build37-unsigned.ipa.sha256
```

`OK` means the check passed. If it says `FAILED`, download both files from the same release again.

Windows PowerShell:

```powershell
Get-FileHash .\simo-0.1.4-build37-unsigned.ipa -Algorithm SHA256
```

Open the `.sha256` file in a text editor and compare its first string with `Hash`. Letter case may differ; all other characters must match.
