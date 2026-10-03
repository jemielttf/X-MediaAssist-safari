# X Media Assist for Safari

Xに投稿された動画はMP4、GIFアニメはgifskiでGIFへ変換してMacのダウンロードフォルダへ保存するSafari拡張です。GIFはXが配信するMP4から再生成するもので、アップロード時の原本GIFを復元するものではありません。


## 保存できるもの

- Xの動画付き投稿に「動画を保存」を追加。タイムラインの追加読み込み・投稿DOMの再利用に追従します。
- Safariのツールバーボタンから、投稿URLを入力して保存することもできます。形式は既定の「Auto」のほか「MP4」を選べます。この選択はポップアップを開いている間だけ有効で、投稿内ボタンは常にAutoです。
- 公開Syndication応答の `mediaDetails[].video_info.variants` から最高ビットレートのMP4を選択します。同値・未指定の場合はURL中の解像度を比較します。
- 複数メディアは順次保存。静止画を除き、元のメディア番号を保持します。
- 保存先は `~/Downloads/投稿者-投稿ID-メディア番号.mp4` または `.gif`。同名ファイルは上書きせず、拡張子の前に半角スペースと数字を付け、`投稿者-投稿ID-メディア番号 2.mp4`、`投稿者-投稿ID-メディア番号 3.mp4` のように保存します。
- 通信と保存の失敗を画面表示。途中まで保存できた場合は、そのファイル名を表示します。

非公開・削除済み・閲覧制限のある投稿、Syndicationで公開されないメディア、ライブ配信/HLS、引用先の自動ダウンロード、静止画は対象外です。引用動画は引用元の投稿を開いてください。MP4の画質選択・保存先変更・履歴・再開機能も今回の対象外です。

## 起動

macOS 14以降のApple Silicon搭載Mac（arm64）のみ対応しています。Intel搭載Mac（x86_64）には対応していません。生成したXcodeプロジェクトはXcode 27形式です。今回の開発・動作確認環境はmacOS 27 / Xcode 27 / Safari 27です。

Rust 1.98.1（rustup）が必要です。Xcodeのビルドフェーズとスクリプトの両方で、同じ固定版gifskiの静的ライブラリを生成します。初回はCargo依存のダウンロードが必要です。FFmpegや外部Gifski.appは不要です。

gifskiは固定コミットを参照するGit submoduleです。新規取得時は `git clone --recurse-submodules https://github.com/jemielttf/X-MediaAssist-safari.git` を使用するか、既存のcloneで以下の初期化コマンドを実行してください。

```bash
git submodule update --init --recursive
rustup toolchain install 1.98.1 --profile minimal
# Apple Silicon向けのターゲットを用意
rustup target add --toolchain 1.98.1 aarch64-apple-darwin
./script/build_and_run.sh
```

CodexのRunボタンも同じコマンドを実行します。アプリは `build/DerivedData/Build/Products/Debug/X Media Assist.app` に生成されます。

1. XcodeのSigning & Capabilitiesで、本体とExtensionの両ターゲットに同じTeamと開発用証明書を設定します。スクリプトもプロジェクトの署名設定を使用し、アドホック署名への上書きは行いません。本体のBundle Identifierは `com.jemielttf.XMediaAssist`、Extensionは `com.jemielttf.XMediaAssist.Extension` です。
2. 案内アプリのボタンからSafariの拡張機能設定を開き、**X Media Assist** を有効にします。見つからない場合はアプリを起動し直し、Safariの設定を開き直してください。
3. 使用するSafariプロファイルで有効にし、Xと `cdn.syndication.twimg.com` へのアクセスを許可してください。
4. 投稿を開き直し、投稿内の「動画を保存」、またはツールバーの拡張ボタンから保存します。
5. 完了表示までタブ・ポップアップを開いておいてください。途中で閉じた場合や通信が切れた場合は、再試行前にダウンロードフォルダを確認してください。

初期MVPの検証ではアドホック署名とSafariの「未署名の機能拡張を許可」を使用しましたが、現在のスクリプトはXcodeの開発用署名設定に従います。配布用の署名・公証・App Store対応は含めていません。

Bundle Identifierを変更した後は、Safariを通常終了して起動し直し、Xのページも再読み込みしてください。Safariが旧Identifierのネイティブ接続先を保持していると、拡張が有効でも保存できないことがあります。保存開始前に接続を確認し、15秒以内に応答しない場合は再起動を案内します。

```bash
./script/build_and_run.sh --build-only  # ビルドのみ
./script/build_and_run.sh --verify      # ビルド・起動・プロセス確認
./script/build_and_run.sh --logs        # 起動してネイティブログを表示
./script/test.sh                        # Node + Swiftの隔離テスト
```

## メニューバーと起動設定

起動中はメニューバーにX Media Assistのアイコンが表示されます。ウインドウを閉じても常駐し、アイコンのメニューから再表示・終了できます。

- **Dockに表示しない**：切り替えはすぐに反映され、次回起動時にも引き継ぎます。初期状態はDockに表示します。
- **ログイン時に起動する**：macOSの `SMAppService.mainApp` で登録・解除します。初期状態は未登録で、システム設定側での変更もメニューを開くたびに反映します。承認が必要な場合は「承認待ち」と表示し、ログイン項目のシステム設定へのメニューを表示します。
- ログイン時の起動では案内ウインドウを隠し、メニューバーから操作できます。通常の手動起動では案内ウインドウを表示します。

ログイン時起動を使う場合は、アプリを継続利用する場所（例：`/Applications`）に置いてから有効にしてください。

## 構成

| 場所 | 責務 |
| --- | --- |
| `Extension/content.js` | 投稿の検出、保存ボタン、結果表示 |
| `Extension/core.js` | URL検証、Syndication解析、MP4選択、保存の順序制御 |
| `Extension/background.js` | メッセージ送信元確認、同時実行制御、nativeMessaging |
| `Extension/popup.*` | URL指定の保存UI |
| `AppSupport/AppPreferences.swift` | Dock表示の設定保存、ログイン項目の登録・解除 |
| `Native/GIFConverter.swift` | AVFoundationでフレーム抽出、libgifski C APIでGIF生成 |
| `Native/MediaSave.swift` | 形式の分岐、GIF失敗時のMP4保持 |
| `Native/MediaDownload.swift` | URLSessionでストリーム保存、応答検証、上書きしない公開処理 |
| `X Media Assist/` | macOS案内アプリ、Safari Web ExtensionのXcodeプロジェクト |
| `Tests/` | JavaScript/Swiftの回帰テスト、ブラウザ用UI fixture |

画面レイアウトの見本は `Docs/layout/main.html` と `Docs/layout/popup.html`、共通CSSの正本は `Docs/layout/style.css` です。`Extension/popup.css` とアプリの `Resources/Style.css` はこのCSSへの相対シンボリックリンクです。管理画面の `Resources/X-Media-Assist.svg` も `X-Media-Assist.icon/Assets/X-Media-Assist.svg` への相対リンクです。リンク先はリポジトリ内で完結し、Xcodeの Copy Bundle Resources がリンクを解決して通常ファイルとしてバンドルします。CSSはリンク先の正本を編集してください。Gitのチェックアウト時はシンボリックリンクを保持してください。

SafariのnativeMessagingは同梱されたApp Extensionが受信し、そのプロセスがダウンロード・変換・保存を行います。GIF基本設定のみ、両ターゲットの App Group `$(DEVELOPMENT_TEAM).com.jemielttf.XMediaAssist.shared` の UserDefaults に共有します。別の常駐ヘルパーやデータベースは導入していません。案内アプリ自体にダウンロード処理を中継する構成ではありません。

## 保存境界と制約

- メディア取得にはログイン情報・Cookie・APIキーを使用しません。公開Syndicationのみに依存します。
- Swiftでも通信先をHTTPSの `video.twimg.com` のMP4へ再検証し、リダイレクトも同じ条件・最大3回に制限します。
- 拡張の権限はsandbox、ネットワーク送信、Downloads書き込みです。
- HTTP 200、Content-Type、Content-Length（ある場合）、MP4 `ftyp` ヘッダーを検査してからファイル名を確定します。完全なMP4デコード検証を毎回行うわけではありません。
- 一度に最大3件、1ファイル1 GiBまで、通信の無応答60秒、転送はGIFアニメ以外の動画10分・GIF変換対象8分までです。
- ネイティブ保存結果の応答待ちは1ファイル650秒まで、画面側の応答待ちは最大4ファイルの順次保存を含め45分までです。これとは別に、保存開始前と保存中の15秒間隔でバックグラウンドへの接続を確認します。確認への応答待ちは15秒で、応答喪失やバックグラウンドの再起動を検出した場合は画面の待機を終了します。接続確認は保存を開始せず、自動再試行もしません。保存先の確認を案内し、待ち時間切れはネイティブ処理のキャンセルを意味しません。
- 一時ファイルを保存先と同じフォルダに作り、完了後に `link(2)` で公開することで既存ファイルの上書きを防ぎます。通常の成功・失敗時は一時ファイルを削除します。プロセスの強制終了で残った `.xma-*` は、最終更新から1時間以上経過したものを接続確認（ping）時に15分以上の間隔で掃除します。保存処理中は掃除を延期し、掃除と新規保存の受付は同じロックで排他制御します。
- 一部保存後に失敗した投稿を再試行すると、保存済みメディアも別名で再保存されます。
- Syndicationは公開仕様の保証がないため、X側の変更で取得できなくなる可能性があります。認証付きAPIへの自動フォールバックは行いません。

## GIF変換

- gifski **1.34.0** をソースからビルドし、品質95/85/70（既定95）、無限ループ、sRGBで出力します。上限fpsは30/25/20/15（既定20）、サイズは100%/75%/50%（既定100%）です。映像の向きとフレーム時刻を反映します。GIFの時間単位は1/100秒です。
- 変換対象の上限は30秒、選択後1,500フレーム、出力1フレーム2,073,600ピクセル（orientation・scale適用後）、入力/出力各100 MiB、変換120秒です。全フレームをメモリへ蓄積せず、順次エンコーダへ渡します。
- 同時変換は1件です。別のGIFが変換中、上限超過、デコード・エンコード失敗などの場合はMP4を保存し、ファイル名と理由を表示します。複数メディアの残りの保存は継続します。
- GIF保存に成功した場合は中間MP4を削除します。不完全なGIFは公開せず削除します。GIFアニメ以外の動画とMP4指定時は変換しません。
- 120秒の時間制限はメタデータ読み込み開始前から計測し、フレーム読み取り・エンコードと共通の期限を使います。メタデータ読み込み中に期限を超えた場合は読み込みの中止を要求し、その終了を待って後始末します。OSのデコード呼び出しや実行中の量子化を即時強制終了する仕組みではありません。拡張プロセスがOSやブラウザに強制終了された場合の復元は未対応です。
- 入力側には別途18,000サンプル・8,294,400ピクセル（4K相当）の上限を設けます。PTSのみ収集・ソートし、先頭PTSを基準とした `1 / maximumFrameRate` 秒の固定区間ごとに、最初の採用可能なフレームを最大1枚選びます。30fps→上限20fpsでは約20fpsとなります。空区間は埋めず、補間・複製・固定fpsへのリサンプリングはしません。設定値は区間あたりの採用枚数の上限で、隣接PTSの最小間隔を示すものではありません。
- 区間境界の候補が前の採用フレームから20ms未満なら落とし、同じ区間の後続候補を検討します。末尾の表示時間が20ms未満になる候補も落とし、直前のフレームを元の終端まで表示します。保持したPTSは変更せず、gifskiによる10ms単位の丸めを除いて元の再生時間を維持します。動画全体が20ms未満のときだけ、単一フレームをgifskiの最小表示時間20msで出力します。
- CoreImageでorientation、原点の正規化、一様scaleの順に適用し、整数ピクセルへ切り下げた出力矩形からRGBA8へレンダリングします。端数寸法では1ピクセル未満の丸めが生じます。
- `Shared/GIFConversionOptions.swift` が許可値と既定値を管理します。基本設定は辞書 `gifConversionOptions` として共有UserDefaultsへ保存し、Dock設定は従来の標準UserDefaultsを維持します。SwiftPMでは共有ターゲット、Xcodeでは同じファイルを両ターゲットへ組み込みます。
- UIの「画質」は高95・中85・低70に対応します。
- Native MessagingのprotocolVersionは3です。pingは基本設定も返し、ダウンロードには `gifOptions` をまとめて渡します。個別設定→基本設定→組み込み既定値の順で解決し、Nativeでも全項目の許可値を再検証します。ポップアップには永続設定の書き込み経路はありません。
- 両ターゲットを同じTeamで署名してください。App GroupはmacOSのTeam ID付き形式を使います。拡張のsandbox・ネットワーク・Downloads権限は維持します。
- 数値の進捗、手動キャンセル、GIFとMP4の両方保存は次段階です。

## ライセンスとソース配布

Copyright 2026 X Media Assist contributors. プロジェクト全体の配布ライセンスは **AGPL-3.0-or-later** です。本文は [LICENSE](LICENSE) を参照してください。第三者コードはそれぞれの著作権表示・ライセンスを維持し、[Licenses/THIRD_PARTY_NOTICES.txt](Licenses/THIRD_PARTY_NOTICES.txt) 、[Rust標準ライブラリの表示](Licenses/Rust-standard-library.html) と [Vendor/README.md](Vendor/README.md) に記録しています。案内アプリの「ライセンス・著作権表示」からもライセンス本文を開けます。

配布はビルド済みアプリを対象とし、自分でビルドする場合はこのリポジトリをcloneしてください。配布ページには、アプリをビルドしたコミットのリリースタグと、そのタグのソース・ビルド手順へのリンクを記載します。

リポジトリ: https://github.com/jemielttf/X-MediaAssist-safari


### 配布版と同じソースからビルドする場合

```bash
git clone --recurse-submodules https://github.com/jemielttf/X-MediaAssist-safari.git
cd X-MediaAssist-safari
git switch --detach <配布ページに記載されたリリースタグ>
git submodule update --init --recursive
```

その後、上記「起動」の手順に従ってRustツールチェーンとXcodeを用意し、両ターゲットのTeam・署名を自分の設定に変更してビルドします。配布者の秘密鍵や証明書はリポジトリに含めません。

親リポジトリのタグがgifskiのコミットを固定し、gifski内の `Cargo.lock` がRust依存を固定します。ビルドには `cargo build --locked` を使用し、Rust自体は `rust-toolchain.toml` で固定します。初回は依存ソースを取得するネットワーク接続が必要です。GitHubが自動生成する「Source code」ZIP/tar.gzにはsubmoduleの実ソースが含まれないため、上記のclone手順を使用してください。

専用のソースアーカイブ作成は通常の配布手順に含めません。ライブラリ更新時は `python3 script/generate_notices.py` で著作権表示を再生成します。配布用署名・公証は別工程です。

## 技術資料

- [Apple: Safari Web Extensions](https://developer.apple.com/documentation/safariservices/safari-web-extensions)
- [Apple: AppとJavaScript間のメッセージ](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)
- [yt-dlp: Twitter extractor](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/twitter.py) — Syndicationの公開埋め込みトークンと応答形式の確認に参照。実行時依存にはしていません。
