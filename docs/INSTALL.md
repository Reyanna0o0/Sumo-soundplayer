# IPA 安装、续签与更新

**已验证：2026-11-23，用户确认 Mac 下载、Sideloadly 安装与首次打开，并确认 build 33 手动测试通过，覆盖更新后此前导入的数据仍在。** Windows、AltStore 和续签尚未实测；其他功能场景仍需分别验证。详细范围见[发布准备状态](RELEASE_STATUS.md)。

**还没下载到安装包？先看[第 1 步：把厮磨安装包下载到电脑](DOWNLOAD.md)。** 那一页从打开 GitHub 开始，说明在哪里点下载、该选哪个文件，以及下载后去哪里找。拿到 `.ipa` 文件后再回到这里。

## 先准备

- iOS / iPadOS 18 或更新版本的设备，一台 Windows 或 Mac 电脑，首次连接使用数据线。
- 自己的 Apple 账户，以及按[下载教程](DOWNLOAD.md)保存到电脑的 `.ipa` 文件。

免费账户的开发签名通常有效 7 天，设备同时可安装的此类 App 通常最多 3 个，还受 App ID 等限额约束；具体以 Apple 账户和签名工具返回为准。到期需要重新签名，不需要先卸载 App。[Apple 账户说明](https://developer.apple.com/help/account/basics/about-your-developer-account/)、[Sideloadly FAQ](https://sideloadly.io/faq.html)

签名时的 Apple 账户登录发生在签名工具中，厮磨本身不需要 Apple 账户登录。项目不收集密码、验证码或签名证书。

## 方式一：Sideloadly（Windows / Mac）

1. 从 [Sideloadly 官方网站](https://sideloadly.io/index.html) 下载对应系统版本。Windows 按官网安装所需的 Apple 驱动、iTunes / iCloud 组件；不要混用官网明确不支持的商店版组件。Mac 按官网适用于当前系统的说明准备。
2. 用数据线连接手机，解锁并点“信任此电脑”。在 Sideloadly 中选中这台设备。
3. 把下载的 `.ipa` 拖入 Sideloadly，输入自己的 Apple 账户。首次使用保留常规选项，不添加插件或修改应用标识。
4. 点击 `Start`，按工具提示完成账户验证，等待签名和安装结束。
5. 若系统提示未受信任的开发者，到“设置 → 通用 → VPN 与设备管理”中信任自己的开发者账户。若提示需要开发者模式，到“设置 → 隐私与安全性 → 开发者模式”开启，并按提示重启、再次确认。[Apple 开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
6. 打开厮磨，先用一份可重新取得的音频测试导入、播放、后台播放和再次启动，再逐步导入正式收藏。

入口或按钮文字可能随工具和系统版本变化，按上述官网当前说明操作。

### 续签

保留首次使用的 Apple 账户、应用标识与签名设置。签名将到期时，用相同 IPA 重新签名并覆盖安装。若启用自动续签，电脑上的 Sideloadly Daemon 需要运行，设备须通过 USB 或已配置的同一 Wi-Fi 被电脑发现；电脑关机时不能依赖它完成续签。[Sideloadly 自动续签说明](https://sideloadly.io/faq.html)

## 方式二：AltStore Classic

按官方 [Windows 安装步骤](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) 或 [Mac 安装步骤](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) 安装 AltServer，再把 AltStore Classic 安装到设备上。这里使用的是 Classic 自签路线。

在设备下载 IPA 后，进入 AltStore 的 `My Apps`，通过 `+` 选择文件并签名安装。续签时确保 AltServer 在电脑运行且设备能连接到它，必要时点 `Refresh All`。免费账户下 AltStore 自己也占一个安装名额。[AltStore 使用说明](https://faq.altstore.io/altstore-classic/your-altstore)

## 更新和保留数据

2026-11-23 的 build 33 更新已获用户手动确认：版本更新成功，之前导入的数据仍在。这是本次实际安装环境的反馈，续签及其他环境仍待验证。

更新时下载新版 IPA，用**同一 Apple 账户、同一工具、同一应用标识**覆盖现有 App。不要先卸载。使用相同标识是覆盖更新的前提，仍需在首次试用阶段确认自己的安装环境能保留数据。[Sideloadly 更新说明](https://sideloadly.io/faq.html)

- 签名过期、安装失败时，先保留原 App，记录报错并检查账户、限额和连接。
- 更换账户、Team 或应用标识可能产生一个独立 App，也可能无法覆盖；不要假定数据会自动迁移。
- 原始音频、视频、字幕请另行保留。重要摘选可导出 MP3 / WAV。当前没有已验收的一键整库备份 / 恢复流程。
- 文件夹导入依赖所选原位置；文件移动或改名后，可在作品菜单重新关联。重新安装不能代替重新关联。

## 常见问题

| 现象 | 处理 |
| --- | --- |
| Safari 下载完无法安装 | 把 IPA 交给上述签名工具，下载本身不是安装 |
| 几天后打不开 | 检查签名是否到期，保持原 App，使用原账户续签 |
| 提示设备 / App ID 数量限制 | 按签名工具报错确认账户限额，等待额度恢复或整理已安装的测试 App |
| 电脑找不到手机 | 先使用数据线、解锁、信任电脑，确认 Apple 驱动可识别设备 |
| 更新后出现两个厮磨 | 检查是否换了账户或应用标识，先保留原 App 与原数据 |
| 无开发者模式选项 | 按 Apple 文档完成连接与开发签名安装步骤后再检查，记录系统版本和提示 |

## 可选：核对下载文件

这一步用于检查下载得到的文件是否与发布附件一致，属于额外核对。先从同一个版本下载 `.ipa.sha256` 文件，把它与 IPA 放在同一个文件夹。

下面命令以当前 build 33 为例，适合已经会使用终端或 PowerShell 的读者；使用其他版本时需替换成实际文件名。打开对应文件夹中的终端 / PowerShell 后运行：

Mac：

```bash
shasum -a 256 -c simo-0.1.0-build33-unsigned.ipa.sha256
```

看到该文件名后跟着 `OK` 表示通过。若显示 `FAILED`，先重新下载 IPA 和同一版本的校验文件再核对。

Windows PowerShell：

```powershell
Get-FileHash .\simo-0.1.0-build33-unsigned.ipa -Algorithm SHA256
```

用记事本打开 `.sha256` 文件，将开头那串字符与命令输出中的 `Hash` 比较，忽略英文字母大小写，其余字符应完全相同。若不同，先确认两个文件来自同一版本，再重新下载核对。
