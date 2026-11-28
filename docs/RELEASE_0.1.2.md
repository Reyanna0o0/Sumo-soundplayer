# 厮磨播放器 v0.1.2 · build 35（正式版）

**简体中文** · [繁體中文](https://github.com/Reyanna0o0/Simo-soundplayer/blob/codex/release-preparation/docs/i18n/zh-Hant/RELEASE_0.1.2.md) · [English](https://github.com/Reyanna0o0/Simo-soundplayer/blob/codex/release-preparation/docs/i18n/en/RELEASE_0.1.2.md) · [日本語](https://github.com/Reyanna0o0/Simo-soundplayer/blob/codex/release-preparation/docs/i18n/ja/RELEASE_0.1.2.md) · [한국어](https://github.com/Reyanna0o0/Simo-soundplayer/blob/codex/release-preparation/docs/i18n/ko/RELEASE_0.1.2.md)

编辑创作者头像时，选图后现在可以调整取景范围。本版也包含照片图库稳定性修补，现已设为正式最新版。

## 下载与更新

**[下载 build 35 IPA](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.2/simo-0.1.2-build35-unsigned.ipa)**

要求 **iOS / iPadOS 18 或更新版本**。

1. 在电脑上点击上方链接，下载完成后在「下载 / Downloads」文件夹找到 IPA。
2. 第一次安装按[安装教程](https://github.com/Reyanna0o0/Simo-soundplayer/blob/codex/release-preparation/docs/INSTALL.md#方式一sideloadlywindows--mac)完成签名安装；已经装过则用原签名方式覆盖安装，**不要先卸载旧版**。

**已经安装 build 35 的用户无需重装。** 转为正式版沿用同一个 IPA，应用与数据库没有额外改动。[下载帮助](https://github.com/Reyanna0o0/Simo-soundplayer/blob/codex/release-preparation/docs/DOWNLOAD.md)

## 头像范围调整

- 在「编辑创作者」中，从照片或文件选择头像后，自动进入「裁剪头像」。
- 拖动图片调整位置，用双指或滑块缩放；圆形框预览最终头像范围，「复位」恢复居中初始范围。
- 点「使用」返回编辑页，再点「保存」完成。取消裁剪保留当前头像；取消整个编辑页放弃本次修改。
- 创作者封面或通话头像继承头像时，也使用选定的范围。作品封面仍采用原有的 4:3 裁剪。

## 验证范围

- 完整 iPhoneOS 和 iPhoneSimulator Release 构建、资源检查及五语文案核对通过。
- 照片选取后取消裁剪、拖动 / 双指 / 滑块 / 复位与保存的界面检查通过；实际裁剪区域、正方形头像、4:3 封面兼容、继承头像读取及取消后保留原图的 App Hosted 检查通过。连续更换后取消编辑的界面与数据复核也通过，已保存头像保留且没有多余草稿。
- 使用独立模拟器与合成资料，未操作用户手机。文件入口共用此裁剪流程；系统文件浏览选中至裁剪的完整界面链路仍未验证，旧照片 / iCloud 下载、第三方云盘与 iPad 布局也需真机复核。详见[验证状态](https://github.com/Reyanna0o0/Simo-soundplayer/blob/codex/release-preparation/docs/RELEASE_STATUS.md)。
- 本版包含 [build 34 图库修补](https://github.com/Reyanna0o0/Simo-soundplayer/releases/tag/v0.1.1)，未改核心或数据库结构；此前 3755 项核心及 9 项选择会话检查的结果记录在 build 34，本轮只新增针对头像裁剪的验证。

## 附件

普通用户只需下载 `.ipa` 并自行签名。`.ipa.json` 和 `.ipa.sha256` 记录构建来源与校验值；`simo-0.1.2-build35-source.zip` 提供对应源码、第三方源材料和重建说明；`LICENSE.txt` 与 `SHA256SUMS.txt` 为许可和附件校验清单。已公开的 build 33 和 build 34 附件保留不变。

[问题反馈](https://github.com/Reyanna0o0/Simo-soundplayer/issues/new?template=bug-report.yml) · [使用许可](https://github.com/Reyanna0o0/Simo-soundplayer/blob/v0.1.2/LICENSE)
