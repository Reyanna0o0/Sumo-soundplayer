# SMB 分阶段诊断与交叉验证

2026-11-25，独立原型；正式 App、系统文件共享、现有用户虚拟机和 NAS 均未修改。此记录更新首轮“目录读取 permissionDenied、根因未明”的结论，原失败记录继续保留。

## 已定位的原始问题

新诊断先复现了相同失败，调用链为：

```text
connect succeeded
stat succeeded
disconnect failed: NSPOSIXErrorDomain / 1
原桥接将整个调用映射为 permissionDenied
```

因此目录属性实际上已取得。为进一步定位，仅在临时依赖 checkout 中增加一次销毁 context 前的观测，获得原始信息：

```text
SMB_SYNTHETIC_SDK_SERVICE result=-1 reason=Read from socket failed, errno:9. Closing socket.
```

固定版 libsmb2 的 LOGOFF 完成回调关闭 fd 后，收包循环又读已关闭的连接，产生 EBADF；AMSMB2 把通用返回值 -1 转成 POSIX EPERM(1)，并在获取错误文本前销毁 context。原桥接又把 EPERM 与明确的 EACCES(13) 一起归为 permissionDenied，使清理错误覆盖成功读取。

上一轮观测用依赖改动已按保存的 SHA-256 和文件权限完全恢复，上一轮测试使用原版固定依赖。随后用户授权在独立工作区复制本地 vendor 并修复；上游 checkout 和远程仓库仍未修改。

## 原型修正

- `AMSMB2Transport` 可注入 `diagnosticSink`，默认 nil。独立记录 connect/stat/list/read/disconnect 的开始、完成或失败，带 operationID、耗时、NSError domain/code 和固定原因标签。
- 不记录密码、账号、路径、主机、SDK manager、完整 userInfo 或原始错误描述。未知 domain 脱敏，底层错误链最多三层。原因标签是辅助分类，不代替原始 code。
- 只读 stat/list/read 已成功后，普通 disconnect 错误保留诊断但不覆盖结果。这一策略不适用于写入事务；本接口没有写入操作。
- 真正的连接/读取失败继续抛出；清理再次失败也不覆盖原错误。任务取消和明确的取消错误始终丢弃结果，不变成成功。
- EPERM(1) 不再无证据地提示权限不足，归为一般无效响应；明确 EACCES(13) 仍为 permissionDenied。

## 交叉验证发现的另一个问题

未启动用户的 Podman 虚拟机，也未配置系统 SMB 服务。使用独立 Python `smbprotocol 1.17.0` 客户端连接同一个 `127.0.0.1:14455` Impacket 0.13.0 合成共享。原夹具上的 12 项交叉检查通过，包括签名认证、目录/中文路径、范围/EOF 读取、完整文件 SHA-256 与错误密码拒绝。这是第二套**客户端**，不是第二种 NAS 服务端。

原夹具的部分错误响应正文不符合规范：失败 CLOSE 仍用正常的 StructureSize=60 正文；失败 SESSION_SETUP 仍用正常登录正文。严格解析器分别报解码错误或误读 ByteCount 后等待超时，遮蔽真实的缺文件/拒绝访问/错误密码状态。这与原始成功读取后的 disconnect 问题是不同故障。

夹具新增显式 `--normalize-error-responses` 模式，只将 CLOSE/INVALID_HANDLE 和 SESSION_SETUP/LOGON_FAILURE 的正文改为 SMB2_ERROR。真实状态码、认证、签名和 MORE_PROCESSING_REQUIRED 均保留，仍由原服务器组包和签名。默认不启用，以便复现原始失败。依据：[Microsoft MS-SMB2 2.2.2](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/d4da8b67-c180-47e3-ba7a-d24214ac4aaa)、[发送错误响应规则](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/41295064-be3f-41dc-9aa5-f68545f945f0)。

另有固定合成路径 `denied.bin`，服务器明确返回 STATUS_ACCESS_DENIED，作为真实拒绝的负向控制；它不是对真实 NAS ACL 的验证。新增协议跟踪记录 handler 状态和最终响应状态、长度及签名自校验布尔值，不记录会话密钥或认证 payload。Impacket 自带 server.log 会包含公开合成账号的认证数据，因此夹具仅供这些合成账号使用，不接入真实凭据。

## 上一轮认证分类限制（历史）

在错误回复正文修正后，AMSMB2 正常读目录、普通/中文文件、非零 offset、EOF 和 probe；缺文件返回 notFound，明确拒绝返回 permissionDenied，成功读取后的 disconnect 问题不再干扰结果。

**未修补的上游固定 SDK 当时不能把错误密码准确分类为需重新授权。** 服务器返回 LOGON_FAILURE，SDK 在认证失败后关闭连接，回调又因 fd 无效被忽略，最终收到通用 EPERM。当前桥接保守返回 invalidResponse，连接被拒绝、没有获得数据，但不会误称授权成功。严格的错误密码分类测试保持失败，不跳过、不放宽断言、不关闭签名。

后续应在隔离环境修复/更换 SDK 的错误传播链，并在真实电脑/NAS 上重新验证；不通过解析测试服务日志推断产品运行时错误，也不按“连接阶段出错”猜测密码一定错误。

## 复现与证据

使用独立 venv 安装 `impacket==0.13.0`。启动本机夹具：

```sh
.venv/bin/python Tests/loopback_smb_fixture.py --normalize-error-responses --evidence /private/tmp/sumo-smb-check
SUMO_SMB_LOOPBACK_SMOKE=1 SUMO_SMB_DIAGNOSTICS=1 swift test --scratch-path /private/tmp/sumo-smb-build
```

上一轮原 SDK 的第二条命令有一个严格认证失败；当前本地修补版 22 项全部通过，原失败日志保留。去掉 `--normalize-error-responses` 可复现原夹具的错误正文问题。测试后用 Ctrl-C 关闭服务。

诊断与生命周期的非网络测试可单独运行：

```sh
swift test --filter SMBDiagnosticsTests
```

本轮完整证据保存在桌面开发目录 `05-测试与验证/Codex-SMB诊断与交叉验证-20261125`。包含原二进制复现、分阶段复现、销毁前诊断、原夹具负向失败、修正正文后的严格测试、独立客户端结果及原依赖恢复证明。最终测试数量与编译结果见该目录 `SUMMARY.md` 和本包 `VALIDATION.json` 的 diagnosticsFollowup 项。

本轮没有验收真实 NAS/外网、SMB3 加密服务端、iPhone 网络、AVPlayer 桥接或实际音频流播；只解决了已定位的原型误报，并细化其余验证边界。

## 本地 vendor 修复与本轮验证

用户随后授权在独立源码树保留完整固定 SDK 并修补。桥接公共 API 不变，仅诊断失败新增可选数值 `ntStatus`；不输出原始描述、主机、路径或凭据。具体改动：

1. Swift 在销毁 context 前保存错误文本和已有 NTSTATUS；终结回调即使 fd 已关闭仍会送达。LOGON_FAILURE 的真实状态 0xC000006D 进入 NSError 元数据。由于上游把它映射为 ECONNREFUSED，桥接仅在携带明确认证 NTSTATUS 时返回 authorizationRequired，单独 ECONNREFUSED 仍是网络不可用。
2. C 收包循环发现终结回调主动关闭 fd 后停止读取，避免成功 LOGOFF 后 readv(-1)；disconnect 的失败回复也不再一律回调成功。网络连接错误保留实际 errno。
3. 新增真实不可用 TCP 测试发现，超时返回后 SDK deinit 仍持有指向旧局部变量的回调指针。调试栈保存于本轮证据。改用稳定对象指针，并在操作栈离开前销毁未完 context、完成/取消回调，防止访问已释放对象。
4. 原桥接只读清理策略继续保留：成功读取不被普通 cleanup 失败覆盖；主要失败和取消始终保留。

本轮使用只绑定 127.0.0.1:14465 的 Impacket 0.13.0 标准化错误正文夹具：全部 22 项测试通过，原严格错误密码断言进一步收紧为 authorizationRequired，并要求原始 NTSTATUS、只发生一次 connect、不进入 stat。改正密码后正常读取和成功 disconnect；缺文件 ENOENT(2)、明确拒绝 EACCES(13) 继续通过。不可用端口在这台 Mac 上实际表现为 5 秒 TCP 超时，返回 timedOut、无 NTSTATUS；没有把网络超时当认证失败。固定错误码单测另验证独立 ECONNREFUSED 映射网络不可用。

Address Sanitizer 下 10 项传输测试通过，包含上述真实路径；关闭 leak 检测，仅证明本次路径无观测到的地址内存错误。generic iOS 编译成功。签名验证、认证交换和加密配置没有被关闭或降级；合成夹具 SMB2 验证不能代表全部 NAS、SMB3 加密、服务器主动映射 guest 或真实 iPhone LAN 情况。客户端没有把被拒绝的账号重试为 guest。

精确补丁与源版本见 `../Vendor/AMSMB2/SUMO_PATCH.md`。本轮完整日志在 `/private/tmp/sumo-smb-vendor-fix-20261125/`，最终归档时随独立测试包保留。原始失败和首次修补暴露的超时崩溃都保留，未覆盖成全绿记录。
