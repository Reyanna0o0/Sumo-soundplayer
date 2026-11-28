# Simo をダウンロード

[简体中文](../../DOWNLOAD.md) · [繁體中文](../zh-Hant/DOWNLOAD.md) · [English](../en/DOWNLOAD.md) · **日本語** · [한국어](../ko/DOWNLOAD.md)

| 安定版 · v0.1.4（build 37） | ベータ版 · v0.1.5（build 38） |
| --- | --- |
| スピーカー再生の保護とバックグラウンド再開条件の改善。 | 設定に NAS 接続（SMB / HTTP / WebDAV）とライブラリ全体のバックアップ・復元を追加。 |
| **[安定版 IPA をダウンロード](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.4/simo-0.1.4-build37-unsigned.ipa)** | **[ベータ版 IPA をダウンロード](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.5-beta.1/simo-0.1.5-build38-unsigned.ipa)** |
| [ソース ZIP](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.4/simo-0.1.4-build37-source.zip) · [更新内容（簡体字中国語）](../../RELEASE_BUILD37.md) | [ソース ZIP](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.5-beta.1/simo-0.1.5-build38-source.zip) · [更新内容（簡体字中国語）](../../RELEASE_BUILD38.md) |

どちらも未署名の IPA で、自分の Apple Account による署名が必要です。同じアプリの二つのリリースから選べます。

**ベータ版はテスト用です。バックアップの復元は現在のライブラリ全体を置き換え、統合はしません。実機での全体復元と家庭用 NAS での受け入れ確認は未完了です。** 重要な元ファイルと既存のアプリを残してください。[ベータ版の対応範囲と制限（簡体字中国語）](../../RELEASE_BUILD38.md)

**iOS / iPadOS 18 以降**が必要です。Windows または Mac でダウンロードしてください。GitHub アカウントは不要です。

## 3 つの手順

1. **上でバージョンを選び、その IPA リンクをクリック**して、ダウンロードが終わるまで待ちます。
2. **選んだバージョンの `.ipa` ファイルを確認します**。「ダウンロード」フォルダを開くか、ブラウザのダウンロード一覧から「フォルダーに表示」「Finder に表示」を選んでください。
3. **署名してインストールします**。IPA を Sideloadly にドラッグし、[インストール手順](INSTALL.md)に従ってください。`unsigned` は未署名という意味で、インストール用ツールが署名を行います。

**すでにインストール済みの場合**は、同じ Apple Account、署名ツール、アプリ識別子で上書きしてください。**先に旧版を削除しないでください。**

## 困ったとき

| 状況 | 対処 |
| --- | --- |
| リンクを押しても反応しない・ダウンロードに失敗する | ブラウザの一覧を確認して再試行します。[リリースページ](https://github.com/Reyanna0o0/Simo-soundplayer/releases)の `Assets` から `.ipa` で終わるファイルを選ぶこともできます |
| ダウンロードしたファイルが見つからない | ブラウザのダウンロード一覧で「フォルダーに表示」「Finder に表示」を選びます |
| IPA をダブルクリックしてもインストールできない | Sideloadly にドラッグし、[インストール手順](INSTALL.md)を進めてください |
| スマートフォンにダウンロードしてしまった | この Sideloadly の手順にはパソコンが必要です。パソコンで同じリンクを開いてください |

解決しない場合は、端末とエラー内容を添えて[不具合を報告](https://github.com/Reyanna0o0/Simo-soundplayer/issues/new?template=bug-report.yml)してください。報告テンプレートは簡体字中国語です。

<details>
<summary>任意：ファイルの検証・ソースの取得</summary>

選んだ[安定版](https://github.com/Reyanna0o0/Simo-soundplayer/releases/tag/v0.1.4)または[ベータ版](https://github.com/Reyanna0o0/Simo-soundplayer/releases/tag/v0.1.5-beta.1)のページから、IPA と同名の `.ipa.sha256` を取得し、[検証手順](INSTALL.md#verify)を実行できます。ソース ZIP も同じバージョンを選んでください。通常のインストールに必要なのは IPA です。

</details>
