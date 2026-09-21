# X Media Assist for Safari

公開Xポストの動画を、最高ビットレートのMP4でMacのダウンロードフォルダへ保存するMVPです。`animated_gif` もMP4のまま保存します。GIF変換は次段階に分離しています。

実施した検証と未確認範囲は [Docs/verification.md](Docs/verification.md) に記録しています。

## MVPの範囲

- Xの動画付きポストに「MP4を保存」を追加。タイムラインの追加読み込み・ポストDOMの再利用に追従します。
- Safariのツールバーボタンから、投稿URLを入力して保存することもできます。
- 公開Syndication応答の `mediaDetails[].video_info.variants` から最高ビットレートのMP4を選択します。同値・未指定の場合はURL中の解像度を比較します。
- 複数メディアは順次保存。静止画を除き、元のメディア番号を保持します。
- 保存先は `~/Downloads/投稿者-投稿ID-メディア番号.mp4`。同名ファイルは上書きせず、拡張子の前に半角スペースと数字を付け、`投稿者-投稿ID-メディア番号 2.mp4`、`投稿者-投稿ID-メディア番号 3.mp4` のように保存します。
- 通信と保存の失敗を画面表示。途中まで保存できた場合は、そのファイル名を表示します。

非公開・削除済み・閲覧制限のあるポスト、Syndicationで公開されないメディア、ライブ配信/HLS、引用先の自動ダウンロード、静止画、GIFへの変換は対象外です。引用動画は引用元のポストを開いてください。画質選択・保存先変更・履歴・再開機能も今回の対象外です。

## 起動

macOS 13以降を対象としています。生成したXcodeプロジェクトはXcode 27形式です。今回の開発・動作確認環境はmacOS 27 / Xcode 27 / Safari 27です。

```bash
./script/build_and_run.sh
```

CodexのRunボタンも同じコマンドを実行します。アプリは `build/DerivedData/Build/Products/Debug/X Media Assist.app` に生成されます。

1. XcodeのSigning & Capabilitiesで、本体とExtensionの両ターゲットに同じTeamと開発用証明書を設定します。スクリプトもプロジェクトの署名設定を使用し、アドホック署名への上書きは行いません。本体のBundle Identifierは `com.jemielttf.XMediaAssist`、Extensionは `com.jemielttf.XMediaAssist.Extension` です。
2. 案内アプリのボタンからSafariの拡張機能設定を開き、**X Media Assist** を有効にします。見つからない場合はアプリを起動し直し、Safariの設定を開き直してください。
3. 使用するSafariプロファイルで有効にし、Xと `cdn.syndication.twimg.com` へのアクセスを許可してください。
4. 公開動画ポストを開き直し、投稿内の「MP4を保存」、またはツールバーの拡張ボタンから保存します。
5. 完了表示までタブ・ポップアップを開いておいてください。途中で閉じた場合や通信が切れた場合は、再試行前にダウンロードフォルダを確認してください。

初期MVPの検証ではアドホック署名とSafariの「未署名の機能拡張を許可」を使用しましたが、現在のスクリプトはXcodeの開発用署名設定に従います。配布用の署名・公証・App Store対応は含めていません。

Bundle Identifierを変更した後は、Safariを通常終了して起動し直し、Xのページも再読み込みしてください。Safariが旧Identifierのネイティブ接続先を保持していると、拡張が有効でも保存できないことがあります。保存開始前に接続を確認し、15秒以内に応答しない場合は再起動を案内します。

```bash
./script/build_and_run.sh --build-only  # ビルドのみ
./script/build_and_run.sh --verify      # ビルド・起動・プロセス確認
./script/build_and_run.sh --logs        # 起動してネイティブログを表示
./script/test.sh                        # Node + Swiftの隔離テスト
```

## 構成

| 場所 | 責務 |
| --- | --- |
| `Extension/content.js` | 投稿の検出、保存ボタン、結果表示 |
| `Extension/core.js` | URL検証、Syndication解析、MP4選択、保存の順序制御 |
| `Extension/background.js` | メッセージ送信元確認、同時実行制御、nativeMessaging |
| `Extension/popup.*` | URL指定の保存UI |
| `Native/MediaDownload.swift` | URLSessionでストリーム保存、応答検証、上書きしない公開処理 |
| `X Media Assist/` | macOS案内アプリ、Safari Web ExtensionのXcodeプロジェクト |
| `Tests/` | JavaScript/Swiftの回帰テスト、ブラウザ用UI fixture |

SafariのnativeMessagingは同梱されたApp Extensionが受信し、MVPではそのプロセスが保存を行います。別の常駐ヘルパー、App Group、データベースは導入していません。案内アプリ自体にダウンロード処理を中継する構成ではありません。

## 保存境界と制約

- メディア取得にはログイン情報・Cookie・APIキーを使用しません。公開Syndicationのみに依存します。
- Swiftでも通信先をHTTPSの `video.twimg.com` のMP4へ再検証し、リダイレクトも同じ条件・最大3回に制限します。
- 拡張の権限はsandbox、ネットワーク送信、Downloads書き込みです。
- HTTP 200、Content-Type、Content-Length（ある場合）、MP4 `ftyp` ヘッダーを検査してからファイル名を確定します。完全なMP4デコード検証を毎回行うわけではありません。
- 一度に最大3件、1ファイル1 GiBまで、通信の無応答60秒、1ファイルの全体時間10分までです。
- ネイティブ保存結果の応答待ちは1ファイル650秒まで、画面側の応答待ちは最大4ファイルの順次保存を含め45分までです。応答喪失時は自動再試行せず、保存先の確認を案内します。待ち時間切れはネイティブ処理のキャンセルを意味しません。
- 一時ファイルを保存先と同じフォルダに作り、完了後に `link(2)` で公開することで既存ファイルの上書きを防ぎます。通常の成功・失敗時は一時ファイルを削除します。プロセスの強制終了では `.xma-*.part` が残る可能性があります。
- 一部保存後に失敗したポストを再試行すると、保存済みメディアも別名で再保存されます。
- Syndicationは公開仕様の保証がないため、X側の変更で取得できなくなる可能性があります。認証付きAPIへの自動フォールバックは行いません。

## 次段階：animated_gif → gifski

`mediaType` はJavaScriptからSwiftまで維持していますが、現段階の出力は常にMP4です。次段階ではSwift側にAVFoundationのフレーム抽出とlibgifskiのエンコードを追加し、GIF/MP4/両方の出力設定、キャンセル、進捗を設計します。gifskiのライブラリ・バイナリ・ライセンスは今回取り込んでいません。組み込み前に配布方針とライセンスを確認します。

## 技術資料

- [Apple: Safari Web Extensions](https://developer.apple.com/documentation/safariservices/safari-web-extensions)
- [Apple: AppとJavaScript間のメッセージ](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)
- [yt-dlp: Twitter extractor](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/twitter.py) — Syndicationの公開埋め込みトークンと応答形式の確認に参照。実行時依存にはしていません。
