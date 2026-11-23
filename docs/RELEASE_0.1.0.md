# 厮磨播放器 v0.1.0 · build 33

首个公开版本，面向个人音声收藏与收听。支持 **iOS / iPadOS 18 或更新版本**，不附带音声作品。下载安装需要 Mac 或 Windows 电脑，以及自己的 Apple 账户。

## 下载与安装

**[下载厮磨 IPA](https://github.com/Reyanna0o0/Sumo-soundplayer/releases/download/v0.1.0/simo-0.1.0-build33-unsigned.ipa)**

1. 下载 `simo-0.1.0-build33-unsigned.ipa`。普通用户只需要这一个文件，无需下载或编译源码。
2. 按[从 GitHub 下载的逐步说明](https://github.com/Reyanna0o0/Sumo-soundplayer/blob/v0.1.0/docs/DOWNLOAD.md)找到文件，再按[安装教程](https://github.com/Reyanna0o0/Sumo-soundplayer/blob/v0.1.0/docs/INSTALL.md)使用 Sideloadly 签名安装。
3. 手机首次打开后，先导入一份可重新取得的音频，确认自己的设备上能够播放。

`unsigned` 表示需要自行签名。下载 IPA 本身不等于安装，不能在 Safari 下载后直接点开安装；免费开发签名需要定期续签，具体操作见安装教程。

已经安装验收版的用户：这是同一份 build 33 IPA，无需为了公开发布再安装一次。后续更新请保留原 App，用同一 Apple 账户、工具和应用标识覆盖安装。

## 这个版本可以做什么

- 整理社团作品和个人音声，管理创作者、声优、社团、封面、收藏与分类。
- 播放、队列、循环、倍速、变调、均衡、睡眠定时，以及后台和锁屏控制。
- 配合字幕、双语字幕与台本收听，调整时间、编辑并保存字幕版本。
- 保存摘选、拼接片段，导出 MP3 / WAV；播放列表和摘选可拖动排序、更改分类，创作者 / 声优 / 社团列表可各自排序。
- 使用模拟语音 / 视频通话外观、图片空间效果，查看收听统计、月度与年度报告。
- 四种外观，支持简体中文、繁体中文、日文、英文和韩文界面。

模拟通话是播放外观，不提供真实通话服务；普通 ZIP、视频格式和链接导入的具体范围见[使用说明](https://github.com/Reyanna0o0/Sumo-soundplayer/blob/v0.1.0/docs/USAGE.md)。

## 已验证与尚待验证

- **用户已验证：** Mac 下载 → Sideloadly 安装 → 首次打开；build 33 手动测试及覆盖更新后此前导入的数据仍在。
- **自动检查已通过：** 3755 项核心自检、独立模拟器 3 项列表操作测试、1346 个界面键 × 5 种语言、设备版 Release 构建与 IPA 内容校验。
- **尚待验证：** 续签到期后的表现、Windows / AltStore 路线，以及更多设备、iPad 布局和媒体组合。
- 构建验证来自同一台 Mac，未在另一台干净电脑上复建；维护者决定后续根据实际反馈修复其他环境问题。

原始媒体请另行保存，重要摘选可导出。目前没有已验收的一键整库备份 / 恢复功能。详见[验证范围](https://github.com/Reyanna0o0/Sumo-soundplayer/blob/v0.1.0/docs/RELEASE_STATUS.md)。

## 附件说明

| 文件 | 用途 |
| --- | --- |
| **`simo-0.1.0-build33-unsigned.ipa`** | **安装包，普通用户下载这一项** |
| `simo-0.1.0-build33-unsigned.ipa.sha256` | 可选：核对 IPA 完整性 |
| `simo-0.1.0-build33-unsigned.ipa.json` | 原始构建信息和二进制源码提交 |
| `simo-0.1.0-build33-source.zip` | 对应应用源码、第三方源材料、构建说明与许可 |
| `LICENSE.txt` | 项目非商业许可文本 |
| `SHA256SUMS.txt` | 上述附件的 SHA-256 校验清单 |

IPA 大小为 **53,206,341 字节**，SHA-256：

```text
25c2f6e53991ea85a89562bf57b0ada302306a9987938c9de2b8821c9ed0f872
```

IPA 实际构建源码提交为 `ed1f0640a1d16d8dc13a248636c8a25845193069`。源码附件从 `v0.1.0` 发布提交导出：应用与构建源码相同，额外包含后续完成的许可、发布文档和反馈模板。LAME / FFmpeg 的完整对应源码、适配和重新链接步骤包含在源码附件中，见[第三方材料](https://github.com/Reyanna0o0/Sumo-soundplayer/blob/v0.1.0/docs/THIRD_PARTY.md)与[构建说明](https://github.com/Reyanna0o0/Sumo-soundplayer/blob/v0.1.0/docs/BUILD.md)。

## 许可与反馈

项目自有代码和明确纳入的视觉素材采用非商业许可：个人非商业使用和修改免费；免费分享修改版须提供对应源码、保留许可与署名并注明非官方；商业使用须事先取得 Reyanna0o0 的书面同意。第三方组件保留各自许可和适用 LGPL 权利。

[问题反馈](https://github.com/Reyanna0o0/Sumo-soundplayer/issues/new?template=bug-report.yml) · [商业授权申请](https://github.com/Reyanna0o0/Sumo-soundplayer/issues/new?template=commercial-license.yml) · [sumo-soundplayer@outlook.com](mailto:sumo-soundplayer@outlook.com)
