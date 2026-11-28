# 0.1.5 测试版 · build 38：NAS 与整库备份

发行标签为 `v0.1.5-beta.1`，App 内版本为 `0.1.5 (38)`。本版与 [0.1.4 正式版](https://github.com/Reyanna0o0/Simo-soundplayer/releases/tag/v0.1.4) 并列提供，保留正式版下载和 Latest 状态。iOS / iPadOS 18 起，仍需自行签名安装。

## 下载

- [测试版 IPA](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.5-beta.1/simo-0.1.5-build38-unsigned.ipa)
- [IPA SHA-256](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.5-beta.1/simo-0.1.5-build38-unsigned.ipa.sha256)
- [对应源码 ZIP](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.5-beta.1/simo-0.1.5-build38-source.zip)

本次公开沿用已交付并收到安装反馈的同一份 IPA，不重新打包；其 SHA-256 为 `5cd24b07c0f2591d80dbc743a11c5aa893c936368f4f30d7b862257223b15baa`。构建源码提交为 `ba4390273a4dca6e98f5a09a31fe748e8f814bde`，发行 tag 只增加发布文档；源码附件对应发行 tag，产品代码与构建提交一致。

## 新增与调整

- **设置 → NAS 与网络来源**：支持电脑／NAS 的 SMB 目录、WebDAV 目录及 HTTP/HTTPS 音频直链。用户手动选择音轨并归入个人音声或社团作品，不扫描整台服务器。来源离线时保留作品资料；修改地址和重新绑定保留作品身份。
- **统一网络播放**：网络音频由 AVPlayer 加载和缓冲，继续使用原播放器界面、队列、字幕时钟和播放位置。网络出错保留当前曲目，可手动重新连接；暂停意图不会被迟到的加载或定位回调覆盖。
- **设置 → 整库备份与恢复**：导出 App 自有资料和媒体；导入后先校验，确认后在下次冷启动切换资料库，并保留回滚副本。
- NAS 与备份页面适配米白、浅黑、紫色；播放列表、摘选等同类删除确认改为屏幕中央提示。

## 换机与恢复

**恢复会替换新机当前的整库，不合并，也不会把相同作品重复导入。** 新机独有的资料如果需要保留，请先单独导出一份备份。

旧机先沿用原账户和应用标识覆盖更新，**不要先卸载**。进入设置导出备份，并另存到电脑或新机可访问的位置；新机签名安装后选择备份、完成校验并确认，按提示关闭再打开 App。核对作品、音频、字幕、列表、摘选、进度和统计后再处理旧机。

备份只包含 App 内数据和媒体。外部文件夹与 NAS 的音频不复制，恢复后重新授权／连接，凭据需要重新填写。作品条目与源文件分开保存；安装后已有作品记录，不代表音频仍存在，也不代表安装包包含私人资料。IPA 不附带用户媒体库、个人作品或备份。

## 验证与已知限制

- 核心 3,755 项、网络导入事务 7 项、访问适配层 79 项、备份核心 21 项检查通过；既有中断策略 33 项、外放保护 27 项通过。
- 专用模拟器：HTTP 的 MP3、M4A、PCM WAV 流播、双向定位、字幕时钟、倍速、暂停优先及手动断线恢复通过；带认证的 SMB/WebDAV 验证了 MP3 基本通路。三套皮肤的实际导出操作和两次冷启动恢复通过。
- 已收到两台 iPhone 安装后可打开的用户反馈；这不等于真机整库恢复、家庭 NAS、后台／锁屏或全部音频格式组合已验收。
- 本轮限速 HTTP 夹具中 M4A 首播等待约 18 秒，尚未解决该等待。WAV 仅覆盖 48 kHz、16-bit、stereo PCM 变体。
- 不含 NAS 按作品离线下载任务管理；网络音频没有完整本地文件时，不提供波形摘选和音频导出。Soundgasm 单作品链接继续使用原有完整下载导入流程，本次没有新增其下载／流播切换入口。
- HTTP/WebDAV 目前提供 Basic／匿名认证；没有 Digest、NTLM HTTP、签名查询 URL 或证书绕过。普通 HTTP 直链不提供目录浏览。

[操作与集中真机清单](NAS_AND_BACKUP.md) · [详细验证范围](NAS_BACKUP_VALIDATION.md) · [安装与更新](INSTALL.md) · [源码重建](BUILD.md)

## Other languages

- **繁體中文**：0.1.5（38）測試版與 0.1.4 正式版並列提供。新增設定中的 NAS 來源及整庫備份／恢復。恢復會取代目前資料庫，不合併或重複匯入；外部資料夾與 NAS 需重新連接。真機整庫恢復與家庭 NAS 尚待驗收。
- **English**: Version 0.1.5 (38) is a beta alongside stable 0.1.4. Settings adds NAS sources and full-library backup/restore. Restore replaces the current library; it does not merge or import duplicates. Reconnect external folders and NAS sources. Full restore on physical devices and home NAS compatibility remain unverified.
- **日本語**：0.1.5（38）は正式版 0.1.4 と並行して提供するベータ版です。設定に NAS ソースとライブラリ全体のバックアップ／復元を追加しました。復元は現在のライブラリを置き換え、統合や重複取り込みはしません。外部フォルダと NAS は再接続が必要です。実機での全体復元と家庭用 NAS の検証は未完了です。
- **한국어**: 0.1.5(38)는 정식 0.1.4와 함께 제공되는 베타 버전입니다. 설정에 NAS 소스 및 전체 라이브러리 백업/복원을 추가했습니다. 복원은 현재 라이브러리를 교체하며 병합하거나 중복 가져오지 않습니다. 외부 폴더와 NAS는 다시 연결해야 합니다. 실제 기기의 전체 복원과 가정용 NAS 호환성은 아직 검증되지 않았습니다.
