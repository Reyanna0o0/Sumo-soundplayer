# 安裝、續簽與更新

**換機提醒：** 系統移轉不保證側載 App 與資料庫恢復成功。請先保留舊機 App 和資料。[移轉與啟動排查](../../MIGRATION.md)

[简体中文](../../INSTALL.md) · **繁體中文** · [English](../en/INSTALL.md) · [日本語](../ja/INSTALL.md) · [한국어](../ko/INSTALL.md)

**[下載穩定版 IPA](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.4/simo-0.1.4-build37-unsigned.ipa) · [下載測試版 IPA](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.5-beta.1/simo-0.1.5-build38-unsigned.ipa)** · [選擇下載版本](DOWNLOAD.md)

可在[下載頁](DOWNLOAD.md)選擇穩定版 v0.1.4（build 37）或測試版 v0.1.5（build 38）。更新時沿用原 Apple 帳號、簽名設定與 App 識別碼，**請勿先移除舊版**。

兩個版本均為未簽名 IPA，需要自行簽名安裝；這是同一 App 的兩個版本選項。

**新版為測試版。還原備份會替換目前整個媒體庫，不會合併。完整真機還原與家庭 NAS 使用仍未完成驗收。** 請保留重要原始檔案與現有 App。[測試版範圍與限制（簡中）](../../RELEASE_BUILD38.md)

首次安裝從下方開始；已安裝的使用者可直接看[更新與保留資料](#update)。

Mac + Sideloadly 安裝與 build 33 覆蓋更新已有實測紀錄；Windows、AltStore 與續簽仍待驗證。詳見[版本說明](../../RELEASE_BUILD37.md)及[完整驗證紀錄（簡中）](../../RELEASE_STATUS.md)。

## 事前準備

- iOS / iPadOS 18 或更新版本的裝置、Windows 或 Mac 電腦，以及首次連接使用的傳輸線。
- 自己的 Apple 帳號與已下載的 `.ipa` 檔案。

免費帳號的開發簽名通常有效 7 天，裝置通常最多可同時安裝 3 個此類 App，另有 App ID 等限制；實際以 Apple 與簽名工具顯示的訊息為準。到期時保留 App，重新簽名即可。[Apple 帳號說明](https://developer.apple.com/help/account/basics/about-your-developer-account/) · [Sideloadly FAQ](https://sideloadly.io/faq.html)

Apple 帳號登入是在簽名工具中進行；廝磨本身無需登入 Apple 帳號，也不收集密碼、驗證碼或簽名憑證。

<a id="sideloadly"></a>
## 方式一：Sideloadly（Windows / Mac）

1. 從 [Sideloadly 官網](https://sideloadly.io/index.html)下載適用版本。Windows 依官網準備 Apple 驅動程式與 iTunes / iCloud 元件，避免混用官網明確不支援的版本；Mac 依目前系統的官方說明準備。
2. 用傳輸線連接裝置，解鎖並點「信任這部電腦」，再於 Sideloadly 選取裝置。
3. 將 IPA 拖入 Sideloadly，輸入自己的 Apple 帳號。首次使用保留一般設定，不加入外掛或變更 App 識別碼。
4. 點 **Start**，依提示完成帳號驗證，等待簽名與安裝結束。
5. 若出現不受信任的開發者提示，到「設定 → 一般 → VPN 與裝置管理」信任自己的開發者帳號。若要求開發者模式，到「設定 → 隱私權與安全性 → 開發者模式」開啟，依提示重新啟動並再次確認。[Apple 開發者模式說明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
6. 開啟廝磨，先用可再次取得的音訊測試匯入、播放、背景播放與重新開啟，再逐步匯入主要收藏。

選單名稱可能隨工具或系統版本而不同，請以官網目前的說明為準。

### 續簽

保留原 Apple 帳號、App 識別碼與簽名設定。簽名即將到期時，以同一 IPA 重新簽名並覆蓋安裝。自動續簽需要電腦上的 Sideloadly Daemon 持續執行，且能透過 USB 或已設定的同一 Wi-Fi 找到裝置；電腦關機時無法依賴它續簽。[自動續簽說明](https://sideloadly.io/faq.html)

## 方式二：AltStore Classic

依官方 [Windows 教學](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)或 [Mac 教學](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos)安裝 AltServer，再將 AltStore Classic 安裝到裝置。這裡使用 Classic 自行簽名的方式。

在裝置下載 IPA 後，進入 AltStore 的 **My Apps**，透過 **+** 選取檔案並簽名安裝。續簽時確保 AltServer 在電腦上執行，且裝置可以連線；需要時點 **Refresh All**。免費帳號下，AltStore 本身也占用一個 App 安裝名額。[AltStore 使用說明](https://faq.altstore.io/altstore-classic/your-altstore)

<a id="update"></a>
## 更新與保留資料

2026-11-23，使用者確認 build 33 更新成功，先前匯入的資料仍在。此結論限於當次安裝環境，續簽與其他環境仍待驗證。

下載新版 IPA，使用**同一 Apple 帳號、同一簽名工具與同一 App 識別碼**覆蓋現有 App，**請勿先移除舊版**。識別碼相同是覆蓋更新的前提，仍須確認自己的安裝環境能保留資料。[Sideloadly 更新說明](https://sideloadly.io/faq.html)

- 簽名到期或安裝失敗時，先保留原 App，記錄錯誤並檢查帳號、額度與連線。
- 更換帳號、Team 或 App 識別碼可能產生獨立 App，或無法覆蓋安裝；資料不一定會自動轉移。
- 請另行保存原始音訊、影片與字幕，重要摘選可匯出 MP3 / WAV。穩定版 v0.1.4 沒有整庫備份、還原入口；測試版 v0.1.5 已在設定新增入口，但還原會**替換整個媒體庫，不會合併**，完整真機還原仍未完成驗收。[測試版說明（簡中）](../../RELEASE_BUILD38.md)
- 資料夾匯入依賴原位置；移動檔案後，請在作品選單重新關聯。重新安裝不能代替重新關聯。

## 常見問題

| 情況 | 處理方法 |
| --- | --- |
| Safari 下載完成卻無法安裝 | 將 IPA 交給上述簽名工具處理 |
| 過幾天後無法開啟 | 檢查簽名是否到期，保留 App 並用原帳號續簽 |
| 出現裝置或 App ID 數量限制 | 依工具訊息確認額度，等待恢復或整理已安裝的測試 App |
| 電腦找不到裝置 | 使用傳輸線、解鎖並信任電腦，確認 Apple 驅動程式可辨識裝置 |
| 更新後出現兩個廝磨 | 檢查是否更換帳號或識別碼，先保留原 App 與資料 |
| 找不到開發者模式 | 依 Apple 文件完成連接與開發簽名安裝後再檢查，記下系統版本與提示 |

<a id="verify"></a>
## 選用：核對下載檔案

從同一版本下載 `.ipa.sha256`，放在 IPA 旁邊，於該資料夾開啟終端機或 PowerShell。以下以 build 37 為例，其他版本須換成實際檔名。

Mac：

```bash
shasum -a 256 -c simo-0.1.4-build37-unsigned.ipa.sha256
```

顯示 `OK` 即通過；若是 `FAILED`，請重新下載同一版本的兩個檔案。

Windows PowerShell：

```powershell
Get-FileHash .\simo-0.1.4-build37-unsigned.ipa -Algorithm SHA256
```

用文字編輯器開啟 `.sha256`，將開頭字串與 `Hash` 比較。英文字母大小寫可不同，其餘字元應完全相同。
