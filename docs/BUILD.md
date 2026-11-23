# 从源码构建

普通使用者只需下载 IPA 并按[安装说明](INSTALL.md)签名。编译源码需要 Mac。

## 环境

- 完整 Xcode，安装 iOS SDK 并完成首次启动组件安装；本轮使用 Xcode 27.2（27B52），没有逐一验证更旧工具链。
- Git、Python 3、Xcode 提供的 Swift / clang / make。`xcode-select -p` 应指向完整 Xcode 的 Developer 目录；也可通过 `DEVELOPER_DIR` 指定。
- App 部署目标 iOS / iPadOS 18.0，核心 Swift package 使用 Swift tools 6.0。
- 首次构建需要网络获取锁定的 ZIPFoundation 0.9.20；LAME、FFmpeg 完整源码和 Core ML 模型已随仓库提供。

本项目目前在同一台 Mac 的独立候选目录完成了核心自检、依赖重建及 App 构建，尚未在另一台干净电脑上复建。跨机器验证不作为本次发布的前置条件；其他环境遇到问题时，请反馈 macOS / Xcode 版本、执行步骤和报错，以便修复构建说明或脚本。

## 克隆与核验

```bash
git clone https://github.com/Gloriaguuuu/simo.git
cd simo
python3 scripts/verify-resources.py
python3 tools/localization/build_resources.py --check
bash scripts/test-core.sh
```

仓库私有时需要当前 GitHub 账户具有访问权限。资源检查覆盖 LAME 上游文件、FFmpeg 归档、模型、三份许可副本和 ZIPFoundation 锁定版本。

## 生成未签名 IPA

```bash
bash scripts/build.sh ipa
```

脚本先从随仓库附带的 FFmpeg 源码构建设备 arm64 和模拟器 arm64 / x86_64 静态库，再用 Release 配置编译 App，并把设备版 `.app` 打包。打包时对副本使用 `strip -S` 去除本机调试路径映射，原构建产物保留。首次构建耗时较长。

产物位于 `dist/`：

- `simo-0.1.0-build33-unsigned.ipa`
- 同名 `.sha256` 文件，供下载校验。
- 同名 `.json` 文件，记录版本、构建号、标识、工具链与源码提交。

该命令关闭代码签名，不使用构建者的 Apple 证书，也不连接手机。生成的包需要用户自行签名；不能作为企业 OTA 包或直接提交 App Store。

仅编译设备版或模拟器版：

```bash
bash scripts/build.sh device
bash scripts/build.sh simulator
```

生成路径为 `.build-support/DerivedData-iphoneos/Build/Products/Release-iphoneos/` 或 `.build-support/DerivedData-iphonesimulator/Build/Products/Release-iphonesimulator/`。模拟器产物不能安装到真机。

## 用 Xcode 安装到自己的设备

1. 先运行 `bash scripts/prepare.sh`，生成 AVI 兼容层的静态库。
2. 打开 `SituationVoicePlayer/SituationVoicePlayer.xcodeproj`，等待 SwiftPM 解析完成。
3. 在 Xcode Settings → Accounts 登录自己的 Apple 账户。
4. 在 App target 的 Signing & Capabilities 中选择自己的 Team，开启自动签名；若默认 Bundle Identifier 无法注册，填写自己的唯一标识。
5. 连接并信任自己的设备，选中 `SituationVoicePlayer` scheme 和该设备，点击 Run。按系统要求开启开发者模式。

后续续签和更新保持同一 Team / Bundle Identifier。初始仓库未配置个人 Team。不要把自己的证书、描述文件、账户配置或 `xcuserdata` 提交进仓库。

## 修改第三方组件后重建

LAME 通过本地 Swift package 从 `ThirdParty/Lame/` 编译；替换兼容源码后，用新的 DerivedData 目录重新编译 App 即可重新链接。资源核验会检测原版源码的变化：有意修改时应复核来源、许可并更新对应 provenance，不能把核验成功冒充未修改上游。

FFmpeg 完整源归档位于 `ThirdParty/FFmpeg/`，构建脚本和全部 configure 选项位于 `SituationVoicePlayer/VideoSupport/build.sh`。默认解压到 `.build-support/ffmpeg/FFmpeg-n8.0.1/`；可在那里修改源码，再运行 `bash scripts/prepare.sh` 重建。之后清理相应 DerivedData 并运行 App 构建，得到重新链接后的 IPA。发行修改版时同时保存修改后的对应源码、配置与许可。

默认构建在静态库已存在时会复用它们；修改桥接代码、FFmpeg 或切换工具链后请主动运行 `prepare.sh`。要完全从附带归档重新开始，可删除**当前克隆目录内**的 `.build-support/` 与 `SituationVoicePlayer/VideoSupport/lib/` 后再构建，这也会删除在临时解压目录内做的修改，操作前先保存补丁。

完整构建材料用于重建与重新链接，不代表源码目录相同就能得到逐字节一致的二进制。编译器版本、路径和签名均可能影响产物。
