# 厮磨播放器 v0.1.1 · build 34（预发布）

本版针对 build 33 在播放期间选照片时反复载入、跳回图库顶部及关闭失灵的反馈，调整了照片和相关文件选择流程。

这是供手机复测的修补预发布版。照片回归、核心检查与构建通过；文件浏览仍有下述验证限制。正式最新版暂时保留 v0.1.0 / build 33。

## 下载与更新

**[下载 build 34 IPA](https://github.com/Reyanna0o0/Sumo-soundplayer/releases/download/v0.1.1/simo-0.1.1-build34-unsigned.ipa)**

普通用户只需下载 `.ipa`，按[安装与更新说明](https://github.com/Reyanna0o0/Sumo-soundplayer/blob/v0.1.1/docs/INSTALL.md)继续使用原来的签名方式覆盖安装。保留原 App，不要先卸载。应用标识与 build 33 相同，本版不更改数据库结构。

## 本版调整

- 创作者头像与封面、作品封面、作品／创作者／个人通话头像和背景，共用由编辑页面持续持有的系统选择面板。播放进度和收听统计刷新时，面板不重新设置图库配置。
- 防止重复打开、旧选择回调串入新的目标；关闭面板后再读取图片或打开裁剪。取消选择不修改草稿，取消编辑仍丢弃未保存的新图片。
- 文件选择面板保留顶部安全区域，让浏览与取消控件正常显示。
- 取消字幕或作品文件选取时直接返回，避免误报曲目变化或闪现导入状态。

## 验证范围

- 3755 项核心检查、9 项选择会话检查通过。
- 完整设备版及模拟器版 Release 构建通过，资源校验通过。
- 独立模拟器上的照片滚动、关闭 / 重开、选图裁剪及保存 / 取消回归通过；相关文件入口关闭 / 重开与真实文件读取、草稿清理检查通过。
- 文件深层浏览仍需真机复核：模拟器的系统「文件」App 对照也无法进入测试文件夹，未完成文件选择至裁剪的完整界面流程。详见[发布与验证状态](https://github.com/Reyanna0o0/Sumo-soundplayer/blob/v0.1.1/docs/RELEASE_STATUS.md)。
- 本版尚未在用户手机的大量旧照片、iCloud 照片下载或第三方云盘中实测；这些场景不记为已经通过。若仍有问题，请记录入口、是否播放中、照片是否在云端以及复现步骤。

## 附件

`unsigned.ipa` 是需要自行签名的安装包；`.ipa.json` 和 `.ipa.sha256` 记录构建来源与校验值。`simo-0.1.1-build34-source.zip` 提供对应源码、第三方源材料和重建说明；`LICENSE.txt` 与 `SHA256SUMS.txt` 分别是项目许可和附件校验清单。原 v0.1.0 / build 33 保留在历史版本中。

[问题反馈](https://github.com/Reyanna0o0/Sumo-soundplayer/issues/new?template=bug-report.yml) · [使用许可](https://github.com/Reyanna0o0/Sumo-soundplayer/blob/v0.1.1/LICENSE)
