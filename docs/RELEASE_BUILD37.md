# v0.1.4 · build 37：后台播放修复与外放保护

本次使用新版本 **0.1.4 / build 37**，独立于此前重新构建的 build 36。保留米白默认、既有五种语言与现有普通字号版式。

## 修复后台意外恢复播放

认可“厮磨事先已暂停，却在其他 App 的音频停止后自行继续”为 Bug：手动暂停应持续有效，不应被迟到的系统或播放回调覆盖。

本次统一处理中断恢复、排队的远程播放命令和画中画播放请求。App 在后台或非活动状态时，中断结束后保持暂停，回到前台也不会自行恢复；用户可从 App、锁屏、耳机或画中画主动继续。前台仅在中断前确实正在播放同一曲目、未被新的手动暂停取消且系统允许时恢复。

用户报告的具体跨 App 事件顺序尚未在真机复现；本次修正的是源码审查发现的恢复条件与回调时序风险，不将画中画写作已确诊的唯一根因。

## 新增外放保护

「设置 → 外放保护」**默认开启**，可关闭。保护只静音厮磨自身，**不修改系统音量**，覆盖普通音频、正式视频、视频附件预览、通话模式和开屏语音。

- 内置扬声器开始播放时默认静音。播放时调节系统音量、点「允许本次外放」，或将输出切换到耳机，可解除静音。
- 暂停后重播、中断后重播或切回内置扬声器时再次保护；同一次持续播放中的换曲沿用当前许可。
- 解除静音和耳机连接不启动已暂停的曲目；耳机断开仍会暂停。
- 音量已达最高/最低，继续按同向音量键没有变化时，可使用「允许本次外放」。开始播放或切换输出后的约 0.75 秒内，系统自动恢复音量不会被当作允许外放；可稍后调节或直接点允许按钮。
- 已暂停或没有厮磨播放任务时，其他 App 的音量变化不能提前解除下一次外放保护。

## 下载与更新

- [未签名 IPA](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.4/simo-0.1.4-build37-unsigned.ipa)
- [IPA 校验文件](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.4/simo-0.1.4-build37-unsigned.ipa.sha256)
- [对应源码 ZIP](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.4/simo-0.1.4-build37-source.zip)

沿用原 Apple 账户、签名设置与应用标识覆盖安装，**不要先卸载旧版**。精确源码提交、SHA-256 和构建信息以本次发布附件为准。[安装与更新](INSTALL.md) · [使用说明](USAGE.md#外放保护与中断后播放build-37-起)

## 验证范围

本轮针对性纯状态检查 **60 项通过、0 失败**（后台恢复 33 项、外放保护 27 项），覆盖暂停意图、后台与非活动状态、迟到回调、路由切换、静音许可、系统音量变化和保护窗口。最终 iPhoneSimulator Release（arm64 / x86_64）与 iPhoneOS Release 构建通过；隔离模拟器安装与启动已完成。这不等同于实际触控界面或设备音频验收。

2026-11-24，维护者在 iPhone 12 Pro Max（iOS 26.7.3）覆盖安装 v0.1.4 / build 37 后反馈“我手动测试好了”“没有问题”，本轮记录为维护者手动真机验收无异常。已通过设备工具确认安装版本为 0.1.4 / 37。反馈未逐项列出耳机类型、音量极值和全部播放模式，不据此宣称所有组合均已覆盖。

Codex 的独立真机 UI 测试在系统认证取消后未能初始化，用例未执行，不计为自动化真机通过；未继续切换设置或导入测试作品。此前的 60 项纯状态检查和构建通过结论保持有效。 最终构建与测试结果以 [发布验证记录](RELEASE_STATUS.md) 为准；逐项认可判断见 [AI 反馈修复记录](AI_REVIEW_FIXES.md)。

## 实现依据

使用 Apple 公开接口：[中断处理与缺少结束通知的情况](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html)、[系统音量与 KVO 观察](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume)、[画中画用户播放请求](https://developer.apple.com/documentation/avkit/avpictureinpicturesamplebufferplaybackdelegate/pictureinpicturecontroller(_:setplaying:))。本功能不监听私人按键接口，也不通过修改系统音量实现静音。
