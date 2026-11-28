# 可选 AMSMB2 传输桥接

2026-11-28 更新：此桥接现已成为正式 App 开发候选的动态 SMB 依赖；当前接入和源码交付说明见 [NAS 与整库备份](../../docs/NAS_AND_BACKUP.md)。以下保留原型阶段的实现及证据记录，原有“未接入”描述不代表当前状态。

这是独立资源访问原型的可选真实 SMB2/3 后端。它不在正式 App 的依赖中，也不在 `ResourceAccess/Package.swift` 的依赖中。主原型的 `ResourceAccessSMB` 只依赖 Core 合同，并通过 `SMBTransport` 注入后端。

**本地 SDK 修补更新：** 先前错误密码分类限制已在独立 vendor 中修复，实际回环 SMB 验证及全部 22 项测试通过，包含错误密码、改正密码后重连、缺文件、明确权限拒绝和不可用 TCP 超时；没有自动重试 guest。另修复成功 LOGOFF 后 EBADF，以及超时退出后失效回调导致的崩溃。修补版和 10 项传输测试通过 Address Sanitizer，generic iOS 未签名编译成功。正式 App 未修改，真实 NAS/iPhone LAN 验证仍需独立测试 App 完成。完整原因见 [DIAGNOSTICS.md](DIAGNOSTICS.md)，精确来源及补丁见 [vendor/SUMO_PATCH.md](../Vendor/AMSMB2/SUMO_PATCH.md)。下方首轮失败记录保留为历史。

## 实现边界

- `SourceConnection` 保存 `smb://host[:port]/share/选定根目录` 和凭据引用。配置解析逐组件解码一次，拒绝编码分隔符、目录穿越、Windows ADS、通配符和控制字符；原始 Unicode/空格文件名可以传入。
- 通过 `CredentialProvider` 临时取得用户名/密码/domain。源记录不保存密码；缺失引用报需授权，不静默降级为 guest；bearer 凭据明确拒绝。可选桥接的 `URLCredential` 使用 `.none` 持久化级别。
- **不编码、不归档、不记录 `SMB2Manager`**：上游 SDK 的 Codable 实现包含密码。
- 目录枚举只暴露单层相对文件名，拒绝恶意条目、重复条目、已报告的链接/特殊文件。只进行读操作。
- `read` 接受 Core 的不超过 1 MiB 范围，使用 SDK 的有界 `contents(atPath:range:progress:)`，不使用其 `.unbounded` AsyncThrowingStream。读前后分别 stat；检测到大小/mtime/hash 变化就丢弃数据；短读、超长读分别拒绝，已知 EOF 返回空数据或最后一段。
- SMB 常规 stat 只有 size/mtime，因此相等仍然是 `RevisionMatch.unknown`，没有生成虚假的 ETag/hash，也没有宣称能安全跨文件替换续传。独立 stat 与 read 不是服务器原子事务；同大小同 mtime 的内容替换无法据此识别。
- `probe` 对非空文件实际读取一个字节，可能在非零位置，才记录观察到的随机读取能力。返回 `.byteReader`；`directPlayback` 明确 unsupported。不能直接把 smb URL 交给 AVPlayer；普通音频精确 seek、持久下载/续传仍由其他层与实际来源验证。
- 每次操作独立建立/断开 SMB 连接，防止一次取消影响其他来源；这是保守原型，会增加连接开销，尚未实现连接池。`requiresEncryption=true` 传给 SDK 的 SMB3 加密选项；不支持的服务器应失败，不自动降级。
- 取消在 Swift Task 边界和 SDK read progress 回调检查，已取消操作不返回成功数据。SDK 没有本适配器可用的每请求即时取消 API；被阻塞的网络调用可能要等 SDK reply timeout，目录枚举也可能要等待当前调用结束。`operationTimeout` 传给 SDK 的网络回复等待设置，不是整个操作的硬性截止时间。
- 路径检查提供词法层面的选定根目录限制。远端服务器如何解析 reparse point/父目录链接不受此适配器控制；尚未验证所有服务器的链接处理，不把这层检查称为安全沙箱。

## 首轮验证结果（2026-11-25，历史记录）

| 验证 | 结果 |
|---|---|
| `ResourceAccess` 中 SMB 注入模拟测试 | 18/18 通过 |
| 此桥接 macOS 原生编译及非网络测试 | 编译成功；3/3 通过；协议测试默认跳过 |
| 此桥接 generic iOS 未签名编译 | `BUILD SUCCEEDED`，Swift 6.4.2 / iOS 27.2 SDK；未安装到手机 |
| 临时 Impacket 0.13.0 loopback SMB2 协议测试 | **未通过**，在目录 metadata 阶段返回 permissionDenied；不是 NAS/电脑共享实测 |

协议测试只绑定 `127.0.0.1:14455`，只共享生成的 64 KiB 数据；没有更改 macOS 文件共享。匿名与公开测试账号尝试均保留。服务器观察到 SMB2 ECHO、CREATE、QUERY_INFO（FileAllInformation）、CLOSE、TREE_DISCONNECT、LOGOFF 返回成功状态，但客户端最终报 permissionDenied。该首轮当时证据不足，不能将那次失败写成通过。后续已定位为断开清理 EBADF；最新本地 vendor 修补没有取消签名或认证。

UTF-8 带空格目录、非零 offset 精确字节、EOF、错误密码等断言已经写入可选协议测试，但该次运行在前面的目录阶段失败，**后续断言没有执行到**。18 项注入测试覆盖的是适配器合同，不冒充实际 NAS 兼容验证。

服务已用 Ctrl-C 关闭，随后 `lsof -nP -iTCP:14455 -sTCP:LISTEN` 无监听。失败记录与协议日志保存在本地 `SmokeEvidence/`，没有运行中的临时服务。

## 重现

在 `Prototypes/ResourceAccess` 中：

```sh
swift test --filter SMBResourceAdapterTests --scratch-path /private/tmp/sumo-resource-access-smb-build
```

在此目录中：

```sh
swift test --scratch-path /private/tmp/sumo-resource-access-amsmb2-build
xcodebuild -scheme ResourceAccessAMSMB2 -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/sumo-resource-access-amsmb2-ios-build -clonedSourcePackagesDirPath /private/tmp/sumo-resource-access-amsmb2-ios-packages -skipPackagePluginValidation build CODE_SIGNING_ALLOWED=NO
```

可选协议夹具使用此目录自己的 `.venv`，不安装到全局 Python，不启动系统共享。首次安装 `impacket==0.13.0` 后，在一个终端运行 `.venv/bin/python Tests/loopback_smb_fixture.py --normalize-error-responses`，另一终端运行（当前验证使用符合标准的错误正文夹具）：

```sh
SUMO_SMB_LOOPBACK_SMOKE=1 SUMO_SMB_DIAGNOSTICS=1 swift test --scratch-path /private/tmp/sumo-resource-access-amsmb2-build
```

测试完关闭夹具。测试账号 `probe` / `fixture-only` 是公开合成数据，不是任何用户凭据。当前修补版本在此合成夹具上全部通过；默认单测不自动启动它。可用 `SUMO_SMB_LOOPBACK_PORT` 与夹具 `--port` 选另一未占用的高端口；地址始终是 127.0.0.1。

## 依赖与许可登记

| 组件 | 固定来源 | 许可/用途 |
|---|---|---|
| AMSMB2 4.0.3 | `1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0` | Swift wrapper 文件声明 MIT；仓库顶层 LICENSE 为 LGPL 2.1；产品声明为 dynamic library |
| libsmb2 子模块 | `aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03` | 库源码 LGPL 2.1-or-later；COPYING 另外标注部分文件的 BSD 条款。静态编译进入 AMSMB2，不可因 wrapper 的 MIT 忽略它 |
| swift-atomics | 上游 manifest 声明从 1.2.0 开始的兼容范围，仅用于其自己的测试目标 | 此桥接未构建上游测试，桥接构建未引入它；当前本地依赖不需要 Package.resolved；不声称将该依赖包含在当前产物中 |
| Impacket 0.13.0 | 独立 Python `.venv` | 仅本地测试夹具，未编译/打包进 Swift 库或 App；其安装元数据标注 `Apache modified`，具体条款见上游 LICENSE，不简化为纯 Apache-2.0 |

固定来源：[AMSMB2 Package](https://github.com/amosavian/AMSMB2/blob/1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0/Package%40swift-6.0.swift)、[README 许可说明](https://github.com/amosavian/AMSMB2/blob/1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0/README.md)、[顶层 LICENSE](https://github.com/amosavian/AMSMB2/blob/1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0/LICENSE)、[libsmb2 COPYING](https://github.com/sahlberg/libsmb2/blob/aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03/COPYING)。

此独立原型未完成正式 App 发布/分发的 LGPL 集成与合规工作，不应仅因为编译成功就把它直接并入发布包。正式依赖选择仍需明确动态链接产物、版权通知、源码及用户权利等交付方式。

## 本地源码与分发

`Package.swift` 通过 `.package(path: "../Vendor/AMSMB2")` 引入完整固定源码，不访问移动分支。SDK 仍声明 dynamic 产品；libsmb2 编译在该库内。`Vendor/AMSMB2` 保留原 LICENSE、COPYING、LICENCE-LGPL-2.1.txt、所有源文件和构建文件，另附原文件哈希、精确 diff、修改说明与最终源码哈希。

独立测试 IPA 的源码交付必须同时带上 `ResourceAccess`、此桥接、完整 `Vendor/AMSMB2` 和 App 工程，允许按 LGPL 条款修改、重编译/重新链接及调试库修改。用户用自己的签名身份重签安装；本包未提供或收集签名证书。具体 IPA 中的动态库嵌入与签名由独立测试 App 的打包检查确认，不能仅根据 Package 声明推断产物。
