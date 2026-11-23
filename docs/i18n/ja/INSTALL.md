# インストール・署名の更新・アップデート

[简体中文](../../INSTALL.md) · [繁體中文](../zh-Hant/INSTALL.md) · [English](../en/INSTALL.md) · **日本語** · [한국어](../ko/INSTALL.md)

**[IPA をダウンロード · v0.1.2（build 35）](https://github.com/Reyanna0o0/Sumo-soundplayer/releases/download/v0.1.2/simo-0.1.2-build35-unsigned.ipa)** · [ダウンロードの案内](DOWNLOAD.md)

初回は以下の準備から始めてください。インストール済みの場合は[データを残して更新する](#update)へ進めます。build 35 の再インストールは不要です。

Mac + Sideloadly のインストールと build 33 への上書き更新には実測記録があります。Windows、AltStore、署名の更新は未検証です。[リリースノート](RELEASE_0.1.2.md)・[検証記録（簡体字中国語）](../../RELEASE_STATUS.md)

## 用意するもの

- iOS / iPadOS 18 以降の iPhone または iPad、Windows または Mac、初回接続用のケーブル。
- 自分の Apple Account と、ダウンロードした `.ipa` ファイル。

無料アカウントの開発用署名は通常 7 日間有効で、この方法で端末に同時インストールできるアプリは通常 3 個までです。App ID などの制限もあり、Apple や署名ツールの表示を優先してください。期限が近づいたら、アプリを残したまま署名を更新します。[Apple のアカウント説明](https://developer.apple.com/help/account/basics/about-your-developer-account/)・[Sideloadly FAQ](https://sideloadly.io/faq.html)

Apple Account へのサインインは署名ツール上で行います。Sumo 自体は Apple Account のログインを必要とせず、パスワード、確認コード、署名証明書を収集しません。

<a id="sideloadly"></a>
## 方法 1：Sideloadly（Windows / Mac）

1. [Sideloadly 公式サイト](https://sideloadly.io/index.html)から OS に合う版を取得します。Windows では Apple ドライバーや iTunes / iCloud の必要な部品を、Mac では現在の macOS に必要な準備を、公式の案内に従って行います。非対応と記載された版の部品を混在させないでください。
2. 端末をケーブルで接続し、ロックを解除してコンピュータを「信頼」します。Sideloadly で端末を選びます。
3. IPA を Sideloadly にドラッグし、自分の Apple Account を入力します。初回は通常の設定を使い、プラグインの追加やアプリ識別子の変更は行わないでください。
4. **Start** を押し、アカウント認証の案内に従って署名とインストールの完了を待ちます。
5. 未信頼の開発元に関する表示が出た場合は、「設定 → 一般 → VPN とデバイス管理」で自分の開発用アカウントを信頼します。デベロッパモードが必要な場合は、「設定 → プライバシーとセキュリティ → デベロッパモード」を有効にし、案内どおり再起動して確認します。[Apple の説明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
6. Sumo を開き、再取得できる音声ファイルで、取り込み・再生・バックグラウンド再生・再起動を確認してから、主なコレクションを取り込んでください。

項目名はツールや OS のバージョンにより異なることがあります。違う場合は公式の最新案内を参照してください。

### 署名を更新する

同じ Apple Account、アプリ識別子、署名設定を使います。期限前に同じ IPA を再署名し、既存のアプリへ上書きしてください。自動更新にはパソコンで Sideloadly Daemon が動作し、USB または設定済みの同じ Wi-Fi で端末を検出できる必要があります。パソコンの電源が切れている間は自動更新を行えません。[自動更新の説明](https://sideloadly.io/faq.html)

## 方法 2：AltStore Classic

公式の [Windows 手順](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)または [Mac 手順](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos)で AltServer を導入し、端末に AltStore Classic をインストールします。ここでは Classic の自己署名方式を使用します。

端末で IPA をダウンロードし、AltStore の **My Apps → +** から選択して署名・インストールします。更新時は AltServer を起動し、端末から接続できる状態にしてください。必要に応じて **Refresh All** を押します。無料アカウントでは AltStore 自体もインストール枠を 1 個使用します。[AltStore の使い方](https://faq.altstore.io/altstore-classic/your-altstore)

<a id="update"></a>
## データを残して更新する

2026 年 11 月 23 日、利用者は build 33 への更新成功と、取り込み済みデータが残っていることを確認しました。この結果はその実測環境に限り、署名の更新や他の環境は未検証です。

新しい IPA を取得し、**同じ Apple Account・同じ署名ツール・同じアプリ識別子**で上書きします。**先に旧版を削除しないでください。** 同じ識別子は上書きの前提ですが、自分の環境でデータが保持されることも確認してください。[Sideloadly の更新説明](https://sideloadly.io/faq.html)

- 署名切れやインストール失敗時はアプリを残し、エラー、アカウントの制限、接続状態を確認します。
- アカウント、Team、識別子を変更すると別のアプリになったり、上書きできなくなったりします。データが自動で移るとは限りません。
- 元の音声・動画・字幕は別途保管してください。重要なクリップは MP3 / WAV で書き出せます。ライブラリ全体のワンクリックバックアップ・復元は未検証です。
- フォルダから取り込んだ作品は元の場所を参照します。移動後は作品メニューから再関連付けしてください。再インストールでは参照先は直りません。

## よくある問題

| 状況 | 対処 |
| --- | --- |
| Safari でダウンロードしたがインストールできない | IPA を上記の署名ツールに渡してください |
| 数日後に起動できなくなった | 署名の期限を確認し、アプリを残して元のアカウントで再署名します |
| 端末数や App ID の制限が出る | ツールの案内で上限を確認し、枠の回復を待つかテスト用アプリを整理します |
| パソコンが端末を認識しない | ケーブル接続、ロック解除、コンピュータの信頼、Apple ドライバーを確認します |
| 更新後に Sumo が 2 つ表示される | アカウントや識別子の変更を確認し、元のアプリとデータを残してください |
| デベロッパモードが見つからない | Apple の接続・開発署名手順を終えてから再確認し、OS と表示内容を記録します |

<a id="verify"></a>
## 任意：ダウンロードしたファイルを検証する

同じリリースの `.ipa.sha256` を IPA と同じフォルダへ保存し、そのフォルダでターミナルまたは PowerShell を開きます。以下は build 35 の例です。他の版では実際のファイル名に置き換えてください。

Mac：

```bash
shasum -a 256 -c simo-0.1.2-build35-unsigned.ipa.sha256
```

`OK` なら一致しています。`FAILED` の場合は、同じリリースから両方のファイルを取得し直してください。

Windows PowerShell：

```powershell
Get-FileHash .\simo-0.1.2-build35-unsigned.ipa -Algorithm SHA256
```

`.sha256` をテキストエディタで開き、先頭の文字列を `Hash` と比較します。英字の大文字・小文字以外は完全に一致する必要があります。
