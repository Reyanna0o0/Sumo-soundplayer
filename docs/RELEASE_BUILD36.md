# v0.1.3 · build 36 重新构建

应用版本仍为 **0.1.3 / build 36**，直接更新现有 `v0.1.3` 发布的附件，不另建修订版发布。新旧 IPA 的版本字段与文件名相同，请通过新 SHA-256 及构建 JSON 中的源码提交区分。

## 本次改动

- 普通字号恢复 build 35 的主要版式，包括媒体库标题与空库提示位置、播放器单排操作、外观横向选择与导入导航栏。仅对标题、按钮和短提示设置字号上限（系统普通字号的最大档 xxxLarge），正文保留系统放大，字幕保留原有字号控制。
- 补齐导入表单、设置和迷你播放器的短控件字号上限；改善深色外观下无收听记录提示的文字对比。
- “从媒体库移除作品”的确认提示改为屏幕中央的警告框。
- 回顾长图使用连续排版：顶部只出现一次月度/年度标题，中间依次安排总时长、收听足迹与排行，底部唱片设计只出现一次。保留秒数，不再直接拼接四张完整页面。
- Soundgasm 音频下载后作为 App 内的独立副本保存；正常移除作品时清理该作品的本地下载副本。外部原文件和已保存的独立摘选保留；ZIP 解压目录的删除策略未改。

米白默认、沉浸通话与现有五种界面语言保持。暂不扩展其他语言。

## 下载与更新

- [未签名 IPA](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.3/simo-0.1.3-build36-unsigned.ipa)
- [IPA 校验文件](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.3/simo-0.1.3-build36-unsigned.ipa.sha256)
- [对应源码 ZIP](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.3/simo-0.1.3-build36-source.zip)，解压根目录为 `Sumo-soundplayer-0.1.3/`。

已有安装可沿用原 Apple 账户、签名设置与应用标识覆盖安装，**不要先卸载旧版**。请同时下载更新后的 IPA 与校验文件，避免把旧 build 36 的同名文件混用。[安装与更新说明](INSTALL.md)

## 验证范围

构建信息见发布附件的 JSON；源码检查、编译、自动化及隔离模拟器多角色检查的具体结果与限制见[验证记录](RELEASE_STATUS.md)。测试结果只适用于记录中的场景，不应扩大为所有设备或真实用户资料均已验证。
