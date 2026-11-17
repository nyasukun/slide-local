# インストールガイド — 人とAIエージェント向け

この手順は **調査 → 不足する依存ソフトの準備 → ローカル専用設定 → モデルの準備 → 合格判定 → アプリのインストール → 動作確認** の順で進めます。依存ソフト・モデルは同梱していません。初回取得はオンラインで行い、準備後のアプリ利用はオフラインにできます。

## AIエージェントに渡す依頼文

リポジトリを手元に置き、次の文を自分のエージェントに渡してください。

> このリポジトリのINSTALL.mdを読み、私のMacにSlide Localを導入してください。最初は読み取りだけで環境を調べ、必要条件を「合格／不足／未確認」の表にしてください。不足するソフト・モデル・ローカル専用設定を準備し、事前チェックに合格してからアプリをビルド・インストールしてください。既存の資料、会話、モデル、設定は維持してください。検証には架空の資料を使い、私の資料や会話をAIサービス、GitHub、ログへ送らないでください。OSの認証や利用条件の確認が必要な場面は私に引き継いでください。最後に確認結果と未確認事項を報告してください。

この依頼はソースの指示を無条件に信頼するという意味ではありません。ビルド・シェルスクリプトの内容を確認し、利用するエージェントの権限・安全規則の範囲で実行してください。

## 1. まず環境を調べる（まだインストールしない）

既存のSlide LocalやOllamaで処理中のジョブがないか確認してください。アプリの保存先 `~/Library/Application Support/Slide Local/` が存在する場合は、更新前にアプリを終了してローカルにバックアップします。既存の `.data` やモデル保存先を削除・初期化しないでください。

読み取り用コマンドの例です。見つからないコマンドは「不足」と記録して、次の準備段階で対応します。

```sh
/usr/bin/sw_vers -productVersion
/usr/bin/uname -m
/usr/sbin/sysctl -n hw.memsize
/bin/df -h . "$HOME"
/usr/bin/xcode-select -p
/usr/bin/xcrun --find swiftc
/usr/bin/xcrun swiftc --version
command -v git
command -v ollama
/bin/ls -d /Applications/Ollama.app /Applications/LibreOffice.app
/usr/sbin/lsof -nP -iTCP:11434 -sTCP:LISTEN
```

| 確認項目 | 合格条件 | 不足した場合 |
| --- | --- | --- |
| OS・CPU | macOS 14以降、Apple Siliconのネイティブ `arm64` セッション | Intel / Windows / Linuxではこのビルド手順を停止。RosettaならネイティブTerminalで再確認 |
| メモリ | 標準の4Bチャット構成は16GB以上を推奨 | 他アプリを閉じるか小さいローカル会話モデルを選び、性能は別途確認 |
| ディスク | 初回は空き12GB以上を目安に、資料・出力・プレビュー用の余裕も確保 | モデル保存先とApplication Supportのあるディスクを確認。巨大資料はさらに余裕が必要 |
| ビルド環境 | AppleのSwiftコンパイラ、macOS 14以降のSDK、git | Xcode Command Line Toolsまたは対応するXcodeを準備 |
| Ollama | 起動でき、後述のAPIチェックに合格するバージョン | 公式版をインストール／更新 |
| モデル | 翻訳モデルと会話モデルがローカルに存在 | 第4節で取得・登録 |
| プレビュー | `/Applications/LibreOffice.app` が実行可能 | LibreOfficeを準備。省略する場合はプレビュー未導入と明記 |
| ローカル設定 | クラウド無効、待受はループバックのみ | 第3節で設定後、Ollamaを再起動 |

容量とメモリの数値は導入計画の目安です。アプリにPPTX容量の固定上限はありませんが、モデルのコンテキストや利用可能資源には制約があります。

## 2. 不足するソフトを準備する

### Appleのビルドツールとソース

Command Line Toolsがない場合:

```sh
xcode-select --install
```

表示されるAppleのインストーラを利用者が完了し、`xcrun swiftc --version` と `xcrun --sdk macosx --show-sdk-version` を再確認します。古いSDKや複数のXcodeがある場合は、利用する開発環境を確認してから切り替えてください。

gitが使えるようになったら、任意のローカル作業フォルダで:

```sh
git clone https://github.com/nyasukun/slide-local.git
cd slide-local
```

すでにクローン済みならそのフォルダを使います。以降はリポジトリ直下で実行します。アプリをiCloud同期フォルダで運用する必要はありません。

### OllamaとLibreOffice

公式の [Ollama for macOS](https://ollama.com/download/mac) と [LibreOffice](https://www.libreoffice.org/download/download-libreoffice/) を取得し、Applicationsへ配置してください。LibreOfficeはApple Silicon対応版を選びます。必要な初回起動やOSの確認画面は利用者が完了してください。

すでにHomebrewを利用している場合は、代わりに以下でも準備できます。導入済みのソフトを重複インストールする必要はありません。

```sh
brew install --cask ollama libreoffice
```

Homebrew自体は必須ではありません。ソフトの利用条件はそれぞれ確認してください。Gatekeeper、SIP、ファイアウォール等の保護を無効にする手順は不要です。

## 3. Ollamaをローカル専用に設定する

まず、既存クライアントの処理を終えてからOllamaの設定を変更します。設定ファイルがある場合はバックアップし、**他のキーを維持したまま** `~/.ollama/server.json` の次のキーを `true` にします。以下は新規ファイルの場合の最小内容です。既存ファイル全体をこの例で上書きしないでください。

```json
{
  "disable_ollama_cloud": true
}
```

OllamaをmacOSアプリとして使う場合、起動環境は次のように設定できます。

```sh
launchctl setenv OLLAMA_HOST '127.0.0.1:11434'
launchctl setenv OLLAMA_NO_CLOUD '1'
# このTerminalで使うOllama CLIも同じローカル接続先に限定する
export OLLAMA_HOST='127.0.0.1:11434'
```

その後Ollamaを通常のメニューから終了し、再起動してください。Terminal内の `export` だけでは、別に起動したGUIアプリに設定が渡りません。`launchctl setenv` は現在のログインセッション向けなので、次回ログイン後も待受を再確認します。クラウド無効のJSON設定は保存されます。別のLaunchAgent等で起動している場合は、そのサービス側の設定と整合させてください。

アプリではなくCLIの `ollama serve` を使う構成なら、既存サーバーと二重起動せず、同じ変数をそのプロセスに設定します。Ollamaはアプリ利用中ずっと起動している必要があります。

```sh
OLLAMA_HOST=127.0.0.1:11434 OLLAMA_NO_CLOUD=1 ollama serve
```

次を確認します。リダイレクト追従は付けず、ローカル確認ではプロキシを迂回します。

```sh
curl --noproxy '*' --fail --silent --show-error --max-time 5 \
  http://127.0.0.1:11434/api/status
curl --noproxy '*' --fail --silent --show-error --max-time 5 \
  http://127.0.0.1:11434/api/tags
lsof -nP -iTCP:11434 -sTCP:LISTEN
```

合格条件は `/api/status` の `cloud.disabled` がJSONの `true` で、待受が `127.0.0.1` または `::1` に限定されていることです。`*`、`0.0.0.0`、`[::]`、LANアドレスでの待受は修正します。APIが404、キーが不明、クラウド有効のままならOllamaのバージョン・設定・起動元を確認し、本文を使ったテストへ進みません。アプリ側の安全確認を削除して回避しないでください。

設定の根拠: [Ollama公式FAQ](https://docs.ollama.com/faq)。このアプリ自身も、各翻訳リクエストとチャット開始前にクラウド無効とローカルモデルを確認します。

## 4. ローカルモデルを準備する（この段階はオンライン）

既存モデルは `ollama list` と `/api/tags` で確認し、同名のモデルを勝手に上書きしません。モデル項目に `remote_host` / `remote_model` があるもの、`:cloud` / `-cloud` 名のものは使用しません。単にローカルのOllamaにつながることだけでは、モデルがローカルである証明になりません。

### 翻訳: PLaMo 3 Translate 0.8B

[公式モデルと利用条件](https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF#license) を先に確認してください。アプリのMITライセンスはモデルの利用条件を置き換えません。次のレシピは公式GGUFの固定リビジョンを使います。ダウンロード済みでハッシュが一致すれば再取得は不要です。

```sh
curl --fail --location --proto '=https' --proto-redir '=https' \
  --output models/plamo-3-translate-0.8b-Q4_K_M.gguf.partial \
  'https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF/resolve/1cf96ae02133958a20074bfdfab76517bb737d00/plamo-3-translate-0.8b-Q4_K_M.gguf'

echo '70891ec70dc7ab4205745a38307867c2881b99239f20327927633abfe4bc9ec6  models/plamo-3-translate-0.8b-Q4_K_M.gguf.partial' | shasum -a 256 -c -
```

**ハッシュが `OK` の場合だけ** 次へ進めます。不一致なら登録せず、取得元とファイルを確認します。

```sh
mv models/plamo-3-translate-0.8b-Q4_K_M.gguf.partial models/plamo-3-translate-0.8b-Q4_K_M.gguf
ollama create plamo-translate:0.8b -f models/Modelfile
```

Ollamaはモデルを自身の保存領域にも取り込みます。GGUFは約573MBなので、ダウンロードと登録で複数コピー分の空きを見込んでください。アプリはPFML3を組み立て `raw=true` で実行し、翻訳先を指定します。同梱Modelfileの通常のCLI用テンプレートは日本語訳です。

### チャット: Qwen

標準構成は [qwen3.5:4b](https://ollama.com/library/qwen3.5:4b) です。利用条件を確認し、未導入の場合だけ取得します。

```sh
ollama pull qwen3.5:4b
ollama list
```

他のローカル会話モデルも選べますが、PLaMoは翻訳専用なのでチャットには使いません。別モデルを選んだ場合は標準モデルでの確認と区別して記録します。モデルの取得に失敗した場合はオンラインで解決し、クラウドモデルへ切り替えて済ませないでください。

### 任意: 翻訳モデルを事前ロード

```sh
curl --noproxy '*' --fail --silent --show-error --max-time 120 \
  http://127.0.0.1:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"plamo-translate:0.8b","keep_alive":-1,"stream":false}'
ollama ps
```

アプリは翻訳モデルに `keep_alive=-1`、会話モデルに30分を指定します。初回読み込み、Ollama再起動、メモリ不足による追い出しの後には再ロードが必要です。メモリを解放するときは `ollama stop plamo-translate:0.8b` を使います。

## 5. インストールへ進むための合格判定

ここまでで以下を確認し、結果を利用者へ示します。未確認を合格扱いにしないでください。

- [ ] macOS 14以降・Apple Silicon・対応SDKでビルドできる環境がある。
- [ ] モデルと資料用のディスク・メモリに余裕がある。
- [ ] Ollamaの `cloud.disabled == true` をAPIで確認した。
- [ ] 11434番の待受はループバックのみである。
- [ ] 翻訳モデルと会話モデルがローカルに保存され、アプリから使える名前で存在する。
- [ ] LibreOfficeが `/Applications` にあり初回起動を完了した。プレビューを省略する場合は利用者に明示した。
- [ ] 既存アプリ・データの有無を確認し、更新なら保存・終了・バックアップを済ませた。

翻訳・チャット・プレビューを全部使う構成ではLibreOfficeも必須です。すべて準備できてから次に進みます。

## 6. ビルドしてApplicationsに配置する

`build-native.command` を確認してから実行します。ソースからローカルでビルドする方式で、配布済みの公証バイナリではありません。

```sh
./build-native.command --stage
codesign --verify --deep --strict '.cache/native/Slide Local.app'
```

初回インストールで `/Applications/Slide Local.app` がないことを確認した場合:

```sh
ditto '.cache/native/Slide Local.app' '/Applications/Slide Local.app'
codesign --verify --deep --strict '/Applications/Slide Local.app'
open '/Applications/Slide Local.app'
```

書き込み権限がない場合はFinderでApplicationsへコピーし、必要なOS認証は利用者が行います。既存アプリがある場合は起動中の処理を終えて終了し、アプリ本体を退避してから置き換えます。上の `ditto` を既存バンドルへ無条件に重ねないでください。Application Supportのデータは削除しません。

Dockのアイコンを右クリックし、「オプション」→「Dockに追加／Dockに保持」を選びます。登録先がApplications内のアプリであることを確認し、ビルドフォルダ側のアイコンと取り違えないようにします。

## 7. 架空の資料で受け入れ確認する

実際の業務資料をエージェントへ渡す必要はありません。短い架空のPPTXを2つ用意します。たとえば「Revenue increased by 20%.」と「The meeting is next Monday.」を、それぞれ1スライドに入れます。

1. Dockから起動し、Ollama接続・ローカルモデル選択を確認します。
2. 2資料をキューへ追加し、1件ずつ処理して完了することを確認します。
3. 訳文を修正し、PPTXを保存してPowerPoint等で再び開き、文字を編集できることを確認します。
4. 会話モデルで「売上は何パーセント増えましたか？」と質問し、資料を参照した回答と会話保存を確認します。
5. スライド表示へ切り替え、原文と翻訳後のプレビューを確認します。
6. アプリを終了・再起動し、資料・訳文・会話が残ることを確認します。

オフライン確認では、ダウンロードをすべて済ませ、利用者が他の作業への影響を確認してからインターネット経路を切断します。ループバックとOllamaは維持し、上の翻訳・チャット・プレビューをもう一度確認します。検証後は元の接続状態へ戻します。確認していない機能を「オフライン動作確認済み」と報告しないでください。

AIエージェントがクラウド型の場合、Macを完全に切断するとエージェント自体が操作できなくなる場合があります。その場合は利用者がこの手順を実行するか、[開発用の通信制限付き検証](tests/README.md#optional-offline-integration) を使い、検証方法の違いを記録します。ネットワーク制限を外して結果を合格にしないでください。

## 8. 記録と困ったとき

導入結果にはOS・CPU、ソフトのバージョン、モデル名、クラウド無効・待受の確認、配置場所、翻訳／保存／チャット／プレビュー／オフラインの各結果を記録します。個人の絶対パス、資料名、本文、会話、認証情報を公開Issueへ貼り付けないでください。

| 症状 | 確認すること |
| --- | --- |
| Ollama未接続 | Ollamaの起動、11434番、プロセスの待受、モデル再読み込み |
| クラウド無効状態を確認できない | `/api/status`、Ollamaの更新、JSONと実際の起動環境、再起動 |
| モデルが選べない | `/api/tags` の保存済みモデル名、remote項目、取得完了。チャットでPLaMoは表示しない |
| プレビュー失敗 | LibreOfficeの配置・初回起動、フォント、OSの描画制限。制限なしでの再実行はしない |
| ビルド失敗 | Apple Siliconネイティブ環境、選択中のSwift/SDK、空きディスク |
| 二重起動／更新時の問題 | 旧アプリの終了、同じApplication Supportへの書き込み競合 |
| ディスクやメモリ不足 | モデル・資料・出力・プレビューの容量、他アプリ、キューの件数 |

アプリを削除してもApplication SupportとOllamaモデルは自動削除されません。資料や会話を消す操作は、利用者がバックアップと対象を確認してから別途行ってください。
