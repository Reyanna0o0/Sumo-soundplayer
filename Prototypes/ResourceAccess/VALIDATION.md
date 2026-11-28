# 独立资源访问接口验证记录

这是首轮接口验证的历史记录。后续已定位并修复 SMB 清理错误覆盖成功读取的问题，本机目录/范围读取已验证，仍有认证错误分类限制；最新结果见 [SMB 诊断与交叉验证](../ResourceAccessAMSMB2/DIAGNOSTICS.md)。原始失败证据保留。

日期：2026-11-25（用户所在 Pacific/Auckland）。正式基线 `b7162d2834ce2918b23c53f76faa65103fb773fc`，独立分支 `codex/resource-access-interfaces`。

## 结果

| 项目 | 结果与证据范围 |
|---|---|
| Core | 18/18：配置/路径、凭据引用、位置保留/重绑、完整拷贝、取消、容量、校验值、等长损坏、旧 probe 晚到 |
| HTTP + WebDAV | 20/20 注入测试：严格 Range、版本、认证、取消、目录解析及范围限制 |
| HTTP 实际本机协议 | 3/3：真实 URLSession + 127.0.0.1 双端口夹具；HEAD/Range/DAV、同源跳转、跨源零访问；没有把沙箱无法启动作为跳过成功 |
| SMB 合同 | 18/18 注入测试：配置、认证、目录、偏移/短读、版本、取消、错误分类 |
| 播放控制 | 20/20：意图优先、串行合并 seek、恢复目标、过期回调、跨来源身份、完整副本、媒体时钟及统计 |
| **主包合计** | **79/79 通过，0 失败、0 跳过** |
| 主包 iOS 编译 | generic iOS / unsigned `BUILD SUCCEEDED`；无编译 warning/error；未安装手机 |
| 可选 AMSMB2 桥接 | macOS 编译成功，3 个非网络测试通过；默认跳过 1 个 opt-in 协议测试 |
| 可选桥接 iOS 编译 | generic iOS / unsigned `BUILD SUCCEEDED`；Swift 6.4.2 / iOS 27.2 SDK；未安装手机 |
| **SMB 本机协议烟测** | **未通过**：目录 metadata 阶段 `permissionDenied`；后续实际范围读取断言未执行，不能算通过 |
| 正式仓库检查 | 工作区干净；前后比较的 265 个源代码/工程/脚本等文件 SHA-256 全部一致，HEAD 未变 |

SMB 烟测仅在本机 `127.0.0.1:14455` 使用合成文件及公开夹具账号，没有改系统共享。服务器部分 SMB2 操作返回 status 0，但客户端最终失败；根因未确认，保留原始日志。临时服务已关闭。详情见 [SMB 验证 JSON](../ResourceAccessAMSMB2/VALIDATION.json) 及 [README](../ResourceAccessAMSMB2/README.md)。

初次整包检查发现 Content-Range 接受 `+4` 这样的非标准数字，已改为严格 ASCII 数字并复测；缓存复核补上弱版本多段拷贝拒绝、已知 hash 校验、等长损坏复核；最终 79 项结果包含这些修正。未隐藏首次失败记录。

## 本轮没有验证的事

- 真实电脑/NAS 的 SMB、WebDAV、HTTPS 证书、实际账号、校园网/VPN/外网、服务器休眠恢复及不同厂商兼容。
- 通过这些新接口完成 MP3/M4A/WAV 的实际 AVPlayer 流播、音频 seek、断线续播、后台/锁屏或字幕同步。此前独立 AVPlayer 探针结论不等于本次新来源已通过。
- 新接口在真实 iPhone 上的网络授权、Keychain 读写、系统文档提供器、后台下载或正式媒体库迁移。
- SMB 弱版本大文件的完整离线下载。当前前台拷贝原型要求强版本或预先已知 SHA-256，不把普通 stat 的大小/mtime 当成一致快照。

因此当前结论是“接口和控制规则已落地，可继续独立联调”，不是“正式版已支持所有 NAS 或 SMB 流播”。

## 复现

主包无需第三方下载依赖。在本目录执行（macOS 测试需要允许仅本机端口）：

```sh
swift test --scratch-path /private/tmp/sumo-resource-access-check
xcodebuild -scheme SumoResourceAccess-Package -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/sumo-resource-access-ios-check build CODE_SIGNING_ALLOWED=NO
```

可选桥接的固定依赖、macOS 测试、iOS 编译和已知失败的协议烟测复现见其 README。未上传 GitHub、未合并到正式分支、未改变正式 App 依赖。

## 证据归档

独立源码保存到桌面开发目录的 `01-源码与工程/独立验证工作区/资源访问接口-20261125`。测试证据保存到 `05-测试与验证/Codex-资源访问接口-20261125`，包含：

- `tests-final.log`：最终 79 项完整测试结果。
- `ios-build.log`：主包 iOS 编译结果。
- `production-baseline.json`、`production-verification.json`：正式源文件校验。
- `initial-tests.log`：首次 Content-Range 失败记录。
- `SMB/`：可选桥接编译、测试与失败协议烟测证据。
- `source-manifest.json`：交付文件清单、hash、分支及提交记录。

不归档临时构建缓存或 Python 虚拟环境；源码包含固定 Swift 包依赖和夹具脚本以便重现。
