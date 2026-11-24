# Sumo Sound Player · 厮磨播放器

> **💛 Tips**
>
> Developing Sumo takes time and effort. Tips are welcome and appreciated!
>
> **[Tips via Stripe](https://donate.stripe.com/7sYcN4ctY5GM3rK3oM7ok00)**

[简体中文](../../../README.md) · [繁體中文](../zh-Hant/README.md) · **English** · [日本語](../ja/README.md) · [한국어](../ko/README.md)

**Stable release v0.1.3 (build 36)** · **iOS / iPadOS 18 or later** · **Free for personal, non-commercial use**

## Download and install

### [Download the IPA · v0.1.3 (build 36)](https://github.com/Reyanna0o0/Sumo-soundplayer/releases/download/v0.1.3/simo-0.1.3-build36-unsigned.ipa)

1. **Open the link on your computer** and wait for the download to finish. No GitHub account is needed.
2. **Find the IPA in Downloads**: `simo-0.1.3-build36-unsigned.ipa`.
3. **Sign and install it with Sideloadly** using the [installation guide](INSTALL.md). For an update, keep your original Apple Account and signing settings, and install over the existing app. **Do not uninstall it first.**

This rebuild keeps app version **0.1.3 / build 36** and replaces the files in release **`v0.1.3`**. Identify the new package by the matching SHA-256 file and the source commit in its build JSON; the app version and filename alone do not distinguish it. Install over the existing app with the same Apple Account, signing settings and app identifier; **do not uninstall first**. [Rebuild notes — Simplified Chinese](../../RELEASE_BUILD36.md)

[Download help](DOWNLOAD.md) · [Installation, renewal and updates](INSTALL.md) · [Release notes](../../RELEASE_BUILD36.md)

## Features

### Two libraries, organized by work and creator

- **Indie Releases** holds complete releases with multiple tracks, covers, scripts and bonus content.
- **Personal Audio** keeps individual creators and their details together. Both libraries support favorites and categories. Creator, voice actor and circle lists can each be reordered by dragging.

### Local imports and folder relinking

Sumo stores your library locally. When you select individual audio or video files, it copies them into the app. When you import a folder, the app continues to read its media from the selected location; supported subtitles, scripts and attachments can be imported alongside multi-track works.

If a linked folder is renamed or moved, open the work's **… → Relink Folder**, select its new location and check the file matches. This keeps the existing work, including edited details, subtitle versions and reading position. [Detailed import instructions — Simplified Chinese](../../USAGE.md#导入作品)

### Soundgasm audio and Scriptbin scripts

Paste a single Soundgasm work link into **Import Works**, preview the title, then download it into the selected library. To attach a Scriptbin script to an existing work, open its link in the script import screen, confirm the web page, extract the text and review it before saving. Saved audio and scripts work offline; fetching them requires internet access. [Link import details — Simplified Chinese](../../USAGE.md#从链接导入)

### Three listening views

- **Normal playback** offers speed, pitch, equalizer and queue controls, repeat modes and a sleep timer. Playback controls also work in the background and on the Lock Screen.
- **Fullscreen Subtitles** lets you read, edit and time scripts. A subtitle window can remain visible over other apps on devices that support picture in picture.
- **Simulated Call** opens from the phone icon in the player. Choose a simulated voice or video call, with per-work avatars, backgrounds and framing. Still-image backgrounds can use an on-device depth effect. This view is for playback; controls such as playback speed are not available here. The call-style buttons control playback and selected images.

Imported videos also have a separate player. Supported playback depends on the file's codec. [Playback details — Simplified Chinese](../../USAGE.md#播放与通话)

### Scripts, bilingual subtitles and manual timing

The app can recognize some script layouts and timing formats. SRT, LRC and supported timed PDF / TXT scripts follow their existing timestamps. Untimed text can be read as a script or timed sentence by sentence in the fullscreen view. You can adjust individual timestamps or shift them together; edits create a new subtitle version.

If you import both the original text and a translation, Sumo can pair and display them together. **Both texts must be supplied by you; the app does not automatically translate.** [Script and subtitle guide — Simplified Chinese](../../USAGE.md#字幕与台本)

### Work details and call appearance

Use **… → Edit Work Details** to change a work's name, library associations and player cover display. Indie releases can have a circle, voice actors and a work number; personal audio can be assigned to a creator. The same editor contains the call character, avatar, background and framing settings. Edit a creator's profile to share a call appearance across that creator's works. Creator avatars can be cropped after selecting a photo or file. [Editing details — Simplified Chinese](../../USAGE.md#作品资料与通话设置)

### Playlists and clips

Build playlists for longer listening sessions. Use the scissors control to mark and save a favorite excerpt as a clip. Clips can retain subtitles, be combined and be exported as MP3 or WAV. Within a playlist or clip category, use **Reorder** to drag items, or the item's **…** menu to change its category. [Playlist and clip guide — Simplified Chinese](../../USAGE.md#播放列表与摘选)

### Launch audio, appearance and languages

In Settings → Launch & Icon, choose your own audio or clip as a launch sound. It is silent by default and, when enabled, plays for up to 10 seconds when the app starts fresh and the playback conditions are met. Four appearances are available: Native, Ivory, Soft Black and Purple. The app supports Simplified Chinese, Traditional Chinese, Japanese, English and Korean.

### Listening statistics and reviews

Explore listening trends, favorite times of day, streaks and rankings by work or voice. Select a date range to see your listening time. Statistics from the two libraries can be combined or viewed separately, and their components can be arranged. Monthly and annual reviews include expandable rankings and can be exported as long images. [Statistics guide — Simplified Chinese](../../USAGE.md#统计外观与语言)

## Your data and content

- **Media and library data stay on your device.** The app stores file references, subtitles, playlists, clips and listening history locally. It does not require an app account or provide a project-operated cloud library or cross-device sync.
- **Network access and sharing follow your actions.** Importing Soundgasm or Scriptbin links contacts those services. Cloud files, exported content and system iCloud backups are handled by the system and providers according to your settings. [Apple's iCloud backup explanation](https://support.apple.com/en-us/108770)
- **Keep copies of your original files.** Relink moved folders, and export important subtitles or clips separately. Keep the existing app when updating or renewing its signature. One-step full-library backup and restore has not been verified.
- **You supply the works.** The IPA includes no audio works or scripts. Import content you are entitled to access and use; consider the original content and personal details before sharing clips, subtitles or reports.

## Development

The [build guide — Simplified Chinese](../../BUILD.md) covers building with Xcode on a Mac, producing an unsigned IPA, and replacing and relinking applicable third-party libraries.

| Directory | Contents |
| --- | --- |
| `SituationVoicePlayer/` | SwiftUI app, resources and Xcode project |
| `hibiki/` | HibikiCore, database, subtitle logic and self-checks |
| `ThirdParty/` | LAME source, FFmpeg archive, depth model licenses and provenance |
| `scripts/` | Resource checks, dependency builds, core checks and IPA packaging |
| `tools/localization/` | Five-language app translations and resource generation |

## License, artwork and contact

The project's own code, build scripts, documentation and covered visual assets use the **Sumo Sound Player Noncommercial Source License 1.0**. Personal, non-commercial use and modification are free. Original and modified versions may be shared free of charge under the license. Keep the license, attribution and project link; modified distributions must include corresponding source and be marked unofficial. **All commercial use requires prior written permission from Reyanna0o0.** See the [license (authoritative Chinese text)](../../../LICENSE) and [commercial-use details — Simplified Chinese](../../COMMERCIAL_USE.md).

Reyanna0o0 provided the icon and launch-screen concepts; a friend contributed authorized hand-drawn revisions, and ChatGPT assisted with base images and animation. Third-party components retain their respective licenses, including applicable LGPL rights to modify, debug, replace and relink. Distributions containing LGPL components must include the corresponding source and rebuilding materials. [Artwork provenance — Simplified Chinese](../../ASSETS.md) · [Third-party materials — Simplified Chinese](../../THIRD_PARTY.md)

For [bug reports](https://github.com/Reyanna0o0/Sumo-soundplayer/issues/new?template=bug-report.yml), include the app version, device system and reproduction steps. Redact personal work names, file paths and account details. The issue templates and detailed technical documents are currently in Simplified Chinese.

[Commercial permission requests](https://github.com/Reyanna0o0/Sumo-soundplayer/issues/new?template=commercial-license.yml) · [sumo-soundplayer@outlook.com](mailto:sumo-soundplayer@outlook.com)
