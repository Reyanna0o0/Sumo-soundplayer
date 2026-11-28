# 换机、数据保留与无法启动排查

系统“快速开始”、App 资料恢复和侧载签名解决的是不同问题。**[0.1.5（build 38）测试版](https://github.com/Reyanna0o0/Simo-soundplayer/releases/tag/v0.1.5-beta.1)** 提供设置 → 整库备份与恢复；[0.1.4 稳定版](https://github.com/Reyanna0o0/Simo-soundplayer/releases/tag/v0.1.4) 保留为稳定入口，没有这一功能。

当前已有核心测试和模拟器备份导出、保存检查。真机反馈仅确认旧机与新机安装后可打开使用，**尚未收到两台真机之间整库恢复完成的验收反馈**；安装成功不等于迁移完成。NAS 支持范围和测试清单见 [NAS 与整库备份](NAS_AND_BACKUP.md)。

## 测试版换机流程

1. **保留旧机 App 和资料。** 使用原有签名身份、安装工具和 App 标识，覆盖更新旧机到 0.1.5（build 38）测试版；不要先卸载。如果安装后出现第二个 App，先核对身份和标识，不要删除原 App。
2. **在旧机导出。** 打开设置 → 整库备份与恢复 → 导出整库备份，等待完成。再把 `.simobackup` 文件保存或复制到电脑等旧机以外、且新机可读取的位置；只把备份留在旧机内不算完成这一步。
3. **安装新机版本。** 为新机签名安装同一测试版或明确兼容的更新版本。如果新机已有独有资料，先另行导出并保存一份备份。恢复会整库替换，不会合并新旧两套资料。
4. **选择备份并校验。** 在新机的整库备份与恢复页面选择旧机备份，等待校验；确认替换后，按页面提示关闭并重新打开 App。为迁移同一套作品无需再手动导入媒体，避免产生重复记录。
5. **核对后再处理旧机。** 检查个人／社团作品、封面、字幕及历史、播放位置、列表、摘选、收听记录、设置和 App 内媒体。外部文件夹与 NAS 音频不在备份中，需要保留原文件，在新机重新授权、关联或连接并输入密码。确认所需资料和音频完整以前保留旧机及独立备份。

<details>
<summary>繁體中文 · English · 日本語 · 한국어</summary>

### 繁體中文

0.1.5（build 38，標籤 `v0.1.5-beta.1`）是提供 NAS 與整庫備份的**測試版**；0.1.4 仍為穩定版，沒有整庫備份入口。已有核心與模擬器檢查，目前真機回饋只確認舊、新機安裝後可開啟使用，尚未確認兩台真機間整庫還原完成。

1. 保留舊機 App，沿用原簽名身分、工具及 App 識別碼覆蓋更新到測試版，不要先解除安裝。
2. 在舊機「設定 → 整庫備份與恢復」匯出 `.simobackup`，並存到電腦等舊機以外、且新機可讀取的位置。
3. 在新機簽名安裝相同或明確相容的版本；若新機已有獨有資料，先另存一份備份。
4. 在新機選擇舊機備份、等待校驗、確認取代，再按提示關閉並重開 App。這是整庫取代，不會合併；同一套作品無須再手動匯入，以免重複。
5. 核對作品、封面、字幕與歷史、進度、清單、摘選、收聽紀錄、設定及 App 內媒體。外部資料夾與 NAS 音訊不隨備份複製，需保留原檔並重新授權／連接及輸入密碼。確認完整以前保留舊機與獨立備份。

### English

**0.1.5 (build 38, tag `v0.1.5-beta.1`) is a beta** with NAS access and full-library backup. 0.1.4 remains the stable release and has no full-library backup entry. Core and simulator checks have been performed. Current physical-device feedback confirms installation and opening on the old and new phones only; a completed full-library restore between those phones has not been confirmed.

1. Keep the old app installed. Update it in place to the beta using the original signing identity, tool and app identifier; do not uninstall first.
2. On the old phone, export a `.simobackup` from Settings → full-library backup and restore. Save or copy it off that phone to a computer or another location the new phone can read.
3. Sign and install the same or an explicitly compatible version on the new phone. Back up any data unique to the new phone separately before proceeding.
4. Select the old phone's backup, wait for validation, confirm replacement, then close and reopen the app as instructed. Restore replaces the entire library; it does not merge libraries. Do not manually import the same works again for this migration, as that may create duplicates.
5. Check works, covers, subtitles and history, playback positions, playlists, clips, listening records, settings and app-owned media. External-folder and NAS audio are not copied into the backup: keep the originals and reauthorize, relink or reconnect them and enter credentials on the new phone. Keep the old installation and independent backup until verification is complete.

### 日本語

**0.1.5（build 38、タグ `v0.1.5-beta.1`）はテスト版**で、NAS とライブラリ全体のバックアップに対応します。0.1.4 は引き続き安定版ですが、全体バックアップの項目はありません。コアとシミュレータの検証は実施済みです。現在の実機報告は旧・新端末でのインストールと起動確認までで、実機間のライブラリ全体の復元完了は未確認です。

1. 旧端末の App を残し、従来の署名 ID・ツール・App 識別子でテスト版を上書き更新します。先にアンインストールしないでください。
2. 旧端末の「設定 → ライブラリ全体のバックアップと復元」から `.simobackup` を書き出し、パソコンなど旧端末以外で新端末から読める場所に保存します。
3. 新端末に同じ版、または互換性が明示された版を署名してインストールします。新端末だけにあるデータは、先に別のバックアップとして保存してください。
4. 旧端末のバックアップを選択し、検証を待って置き換えを確認した後、画面の指示どおり App を終了して開き直します。ライブラリ全体を置き換える操作であり、統合ではありません。同じ作品を再度手動で読み込む必要はなく、重複の原因になります。
5. 作品、カバー、字幕と履歴、再生位置、リスト、抜粋、再生記録、設定、App 内メディアを確認します。外部フォルダと NAS の音声はバックアップに含まれません。元ファイルを保管し、新端末で再認可・再関連付け・再接続と認証情報の入力を行います。確認が終わるまで旧端末と別途保存したバックアップを残してください。

### 한국어

**0.1.5(build 38, 태그 `v0.1.5-beta.1`)는 테스트 버전**이며 NAS와 전체 라이브러리 백업을 지원합니다. 0.1.4는 계속 안정 버전으로 제공되지만 전체 백업 메뉴는 없습니다. 핵심 기능과 시뮬레이터 검증은 진행했습니다. 현재 실기기 피드백은 기존·새 휴대폰에서 설치 및 실행이 가능하다는 확인까지이며, 두 실기기 사이의 전체 복원 완료는 아직 확인되지 않았습니다.

1. 기존 앱을 유지하고 원래 서명 계정, 도구, 앱 식별자로 테스트 버전을 덮어써 업데이트하세요. 먼저 삭제하지 마세요.
2. 기존 휴대폰의 ‘설정 → 전체 라이브러리 백업 및 복원’에서 `.simobackup`을 내보내고, 컴퓨터 등 기존 휴대폰 밖이면서 새 휴대폰에서 읽을 수 있는 곳에 저장하세요.
3. 새 휴대폰에 같은 버전 또는 호환성이 명시된 버전을 서명하여 설치하세요. 새 휴대폰에만 있는 자료는 먼저 별도 백업으로 저장하세요.
4. 기존 휴대폰의 백업을 선택하고 검증을 기다린 뒤 교체를 확인하세요. 안내에 따라 앱을 완전히 종료하고 다시 여세요. 전체 라이브러리를 교체하며 병합하지 않습니다. 같은 작품을 다시 수동으로 가져올 필요가 없으며, 다시 가져오면 중복될 수 있습니다.
5. 작품, 표지, 자막과 이력, 재생 위치, 목록, 발췌, 청취 기록, 설정과 앱 내부 미디어를 확인하세요. 외부 폴더 및 NAS 음원은 백업에 복사되지 않습니다. 원본을 보관하고 새 기기에서 다시 권한을 부여하거나 연결하고 인증 정보를 입력하세요. 확인이 끝날 때까지 기존 설치와 별도 백업을 유지하세요.

</details>

## 重新安装后为什么仍有作品

重新安装或在新机安装后出现旧作品，可能是系统迁移、备份恢复或保留下来的 App 资料。作品记录与源媒体文件独立：资料库里能看到作品，不代表音频一定在当前设备或已获得访问授权；“目录无法刷新”也不能据此认定 IPA 自带作品或文件已经丢失。应分别核对安装包内容、当前数据库、实际媒体位置和访问权限。

若媒体随系统搬到了新容器，旧的绝对路径或目录授权仍可能失效；若媒体留在外部文件夹或 NAS，也需重新关联或连接。先核对并恢复关联，不要急于删除作品或重复导入。

- **繁體中文**：重新安裝後出現舊作品，可能來自系統移轉、備份還原或保留的 App 資料。作品紀錄與媒體檔案獨立；目錄刷新失敗不代表 IPA 帶有作品，也不證明檔案已遺失。請分別核對安裝包、資料庫、實際檔案及權限；先恢復關聯，不要刪除或重複匯入。
- **English**: Old works appearing after installation may come from migrated, restored or retained app data. Catalogue records and media files are separate: a directory refresh failure does not establish that the IPA contains those works or that the files are lost. Check the package, database, actual files and permissions separately. Restore access or relink before deleting or importing duplicates.
- **日本語**：再インストール後の旧作品は、移行・復元・保持された App データに由来する可能性があります。作品情報とメディアファイルは別です。フォルダ更新の失敗だけでは、IPA に作品が含まれることも、ファイル消失も判断できません。パッケージ、データベース、実ファイルと権限を個別に確認し、削除や再読み込みの前にアクセスや関連付けを復旧してください。
- **한국어**: 재설치 후 보이는 기존 작품은 이전·복원되거나 유지된 앱 데이터일 수 있습니다. 작품 기록과 미디어 파일은 별개이므로 폴더 새로고침 실패만으로 IPA에 작품이 들어 있다거나 파일이 사라졌다고 판단할 수 없습니다. 설치 패키지, 데이터베이스, 실제 파일과 권한을 각각 확인하고, 삭제하거나 중복으로 가져오기 전에 연결과 접근 권한을 복구하세요.

## 旧手机暂时不要卸载

先保留旧手机、原 App 和现有备份。不要把卸载重装、抹掉设备或清理数据当作第一步。记录安装方式、App 版本、系统版本及准确错误提示。

- **提示 App 不可用、无法验证或开发者未受信任：** 检查签名、信任与开发者模式。需要续签时沿用原 Apple 账户、工具和应用标识覆盖安装；不要先卸载。Sideloadly 的说明要求覆盖时使用相同 Apple ID 和 bundle ID；这不是对任意数据环境的恢复保证。[Sideloadly FAQ](https://sideloadly.io/faq.html)
- **点击后立即退出：** 先读取本次启动的系统日志或崩溃报告。签名启动拒绝、动态库加载失败和程序内部崩溃需要不同处理；不要仅凭“闪退”认定签名过期，也不要用较早的无关日志解释新问题。
- **App 可打开但文件无法访问：** 先核对原媒体是否存在及访问权限，再用作品菜单中的重新关联功能。不要通过删除作品来尝试恢复关联。

## 新手机没有厮磨

新设备可能需要用自己的签名工具为该设备重新签名安装。即使安装后能正常打开，也不能证明旧库已恢复；分别核对作品资料、字幕、摘选、列表、收听记录和原始媒体。确认恢复完整以前保留旧设备和备份。

[Apple 快速开始说明](https://support.apple.com/zh-cn/102659)描述系统迁移；[Apple 开发账户说明](https://developer.apple.com/help/account/basics/about-your-developer-account/)说明个人开发签名限制。两者都不代替本 App 的整库迁移验收。

## 文件 App 中的目录不是完整资料库

当前数据库位于 App 的 Documents，使用 SQLite WAL；部分音频副本、摘选、封面和升级前数据库快照位于 Library/Application Support。外部文件夹还依赖原文件及访问授权。因此：

- 只拷贝文件 App 中能看到的“厮磨”目录，不等于完整备份。
- 单独拷贝一个数据库文件，不保证包含尚在 WAL 中的数据；不要在正在写入时随意拼接数据库文件。
- 升级前数据库快照不是完整媒体备份，不能当作已验收的恢复入口。
- 可继续单独保存原媒体、字幕和重要摘选导出；请同时保留已有整机备份，但不要将备份存在等同于恢复验证完成。

如果需要协助诊断，只提供与厮磨相关的错误信息；分享前遮住账号、设备标识、私人作品名及路径。
