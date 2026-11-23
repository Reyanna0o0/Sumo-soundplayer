# 设计素材与 UI 色卡

归档日期：2026-11-23。这里保存可复用的自有设计资料，供查看、非商业使用和后续开发参考。

- [UI 色卡 HTML](palettes/index.html)：下载后用浏览器打开，包含米白、浅黑色、紫色与报告故事页色值。
- 静态色卡：[米白](palettes/porcelain.svg)、[浅黑色](palettes/graphite.svg)、[紫色](palettes/purple.svg)。[JSON 色值](palettes/palettes.json)保留用途、源码标识和渐变参考。
- [开屏动画预览 HTML](splash/preview.html)：原始美术动画预览，下载后打开。App 中的实际布局由 SwiftUI 实现；本文件不是手机录屏。
- [正式 App 图标](../SituationVoicePlayer/Sources/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png)、[开屏原图](../SituationVoicePlayer/Sources/Assets.xcassets/LaunchArtwork.imageset/splash-original.png)、[动效参数](../SituationVoicePlayer/Sources/Assets.xcassets/LaunchMotion.dataset/splash-motion.json)已保存在源码中。

色卡从当前 AppTheme.swift 提取；原生外观使用 iOS 动态语义色，不是固定 HEX。HEX 也不代表透明度叠加后的每个屏幕像素。报告故事页固定色与三套界面皮肤分别列出。

来源与授权沿用[美术素材说明](../docs/ASSETS.md)和[项目许可证](../LICENSE)。图标／开屏创意为 Reyanna0o0，手绘由已授权友人协助，底图与动效由 ChatGPT 辅助生成。

这些文件作为设计归档保存，不改变已发布 IPA 或既有 release 标签。
