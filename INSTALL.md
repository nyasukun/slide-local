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
command -v brew
/bin/ls -d /Applications/LibreOffice.app
/usr/sbin/lsof -nP -iTCP:11434 -sTCP:LISTEN
```

Homebrewがある場合は `brew services list` と `brew list --formula ollama` も確認します。既存GUI版の有無は `/Applications/Ollama.app` とログイン項目から調べますが、**GUIアプリがなくてもCLIサービスが使えれば合格**です。`OLLAMA_HOST` / `OLLAMA_MODELS` などの既存設定、LaunchAgent、`launchctl getenv OLLAMA_HOST` も確認し、モデル保存先や待受の変更が必要か調べます。設定やログに認証情報があっても公開しないでください。

| 確認項目 | 合格条件 | 不足した場合 |
| --- | --- | --- |
| OS・CPU | macOS 14以降、Apple Siliconのネイティブ `arm64` セッション | Intel / Windows / Linuxではこのビルド手順を停止。RosettaならネイティブTerminalで再確認 |
| メモリ | 標準のTranslateGemma12B＋4Bチャット構成は24GB以上を推奨 | 他アプリを閉じるか小さいローカルモデルを選び、性能は別途確認 |
| ディスク | 初回は空き20GB以上を目安に、資料・出力・プレビュー用の余裕も確保 | 標準モデルは合計約11.5GB。モデル保存先とApplication Supportのあるディスクを確認 |
| ビルド環境 | AppleのSwiftコンパイラ、macOS 14以降のSDK、git | Xcode Command Line Toolsまたは対応するXcodeを準備 |
| Ollama | 起動でき、後述のAPIチェックに合格するバージョン | 公式版をインストール／更新 |
| モデル | 翻訳モデルと会話モデルがローカルに存在 | 第4節で取得・登録 |
| プレビュー（任意） | 使用する場合は `/Applications/LibreOffice.app` が実行可能 | LibreOfficeを準備。省略しても読み込み・翻訳・保存・質問は利用可能。プレビュー未導入と明記 |
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

### Ollama（標準: CLI版）

**標準はGUIを使わないCLI＋ログイン時自動起動構成です。** Homebrewがなければ、利用者の了承を得て [Homebrew公式サイト](https://brew.sh/) の手順で準備し、表示されるPATH設定を完了してください。OSの認証や利用条件の確認は利用者が行います。

CLI版が不足する場合だけ導入します。`--cask` は付けません。まだサービスは起動せず、第3節でローカル専用に設定します。

```sh
brew install ollama
```

裸の `ollama` や `ollama launch` による対話式セットアップは不要です。**Claude Code・Codex等との連携、OllamaへのサインインはSlide Localには不要**で、案内されてもスキップできます。他の開発ツールの接続設定は変更しません。

既存のGUI版や別のサービスが正常なら、そのまま使うこともできます。CLI版への移行は、処理中ジョブがないこと、モデル保存先と既存設定を維持できることを確認し、利用者の了承を得てから行います。GUI版の削除は不要です。GUI版を終了し、そのログイン時自動起動を無効にしてからCLIサービスを開始します。別サービスがある場合も、起動元を特定して二重起動を解消するまでは新規サービスを開始しません。`brew link --overwrite` やモデル削除で競合を解消しないでください。

Homebrewを使わない既存GUI構成では、公式の [Ollama for macOS](https://ollama.com/download/mac) をApplicationsへ配置して手動起動します。Slide Local自身はOllamaを起動・停止しません。

### LibreOffice

LibreOfficeは**スライド画像のプレビュー作成にだけ必要**です。資料の読み込み・選択・翻訳・PowerPoint保存・質問には不要です。プレビューを使わない場合は導入を省略できます。

Slide LocalがLibreOfficeを使用するのは、利用者が「プレビューを作成・更新」を押したときだけです。「スライド画像を確認」へ表示を切り替えるだけでは起動しません。別の資料を開くと文章表示に戻り、プレビューを自動作成しません。

[LibreOffice公式版](https://www.libreoffice.org/download/download-libreoffice/) のApple Silicon対応版を取得し、Applicationsへ配置してください。Homebrewでは `brew install --cask libreoffice` でも準備できます。必要な初回起動やOSの確認画面は利用者が完了してください。

ソフトの利用条件はそれぞれ確認してください。Gatekeeper、SIP、ファイアウォール等の保護を無効にする手順は不要です。

## 3. Ollamaをローカル専用に設定する

まず、既存クライアントの処理を終えてからOllamaの設定を変更します。設定ファイルがある場合はバックアップし、**他のキーを維持したまま** `~/.ollama/server.json` の次のキーを `true` にします。以下は新規ファイルの場合の最小内容です。既存ファイル全体をこの例で上書きしないでください。

```json
{
  "disable_ollama_cloud": true
}
```

### 標準: CLIサービスをログイン時に自動起動する

上のJSON設定は再ログイン後も有効です。Ollamaの既定の待受は `127.0.0.1:11434` なので、そのまま使います。既存の `OLLAMA_HOST` やサービス定義に外部公開設定がある場合は、利用者と影響を確認して起動元側で修正し、以下の実測チェックに合格するまで進めません。Terminal内の `export` や `launchctl setenv` を永続的なサービス設定の代わりにしないでください。

11434番を使う既存サーバーがないことを再確認してから、**sudoを付けず**に実行します。

```sh
brew services start ollama
brew services list
# このTerminalで使うOllama CLIも同じローカル接続先に限定する
export OLLAMA_HOST='127.0.0.1:11434'
```

ユーザーサービスとしてログイン時に自動起動します。Terminalを閉じても動作し、Slide Localを終了しても停止しません。既存のHomebrewサービスにJSON設定の変更を反映する場合は、ジョブ終了と利用者の了承を確認して `brew services restart ollama` を実行します。GUI版や別サービスに対してこのコマンドで再起動しようとしないでください。

### 代替: 既存のGUI版・手動CLI

GUI版を継続利用する場合に限り、起動環境は次のように設定できます。標準のCLIサービスと同時には起動しません。

```sh
launchctl setenv OLLAMA_HOST '127.0.0.1:11434'
launchctl setenv OLLAMA_NO_CLOUD '1'
# このTerminalで使うOllama CLIも同じローカル接続先に限定する
export OLLAMA_HOST='127.0.0.1:11434'
```

その後Ollamaを通常のメニューから終了し、手動で再起動してください。Terminal内の `export` だけでは、別に起動したGUIアプリに設定が渡りません。`launchctl setenv` は現在のログインセッション向けなので、次回ログイン後も待受を再確認します。クラウド無効のJSON設定は保存されます。別のLaunchAgent等で起動している場合は、そのサービス側の設定と整合させてください。

アプリではなくCLIの `ollama serve` を使う構成なら、既存サーバーと二重起動せず、同じ変数をそのプロセスに設定します。Ollamaはアプリ利用中ずっと起動している必要があります。

```sh
OLLAMA_HOST=127.0.0.1:11434 OLLAMA_NO_CLOUD=1 ollama serve
```

### 起動後の確認（すべての構成で必須）

次を確認します。リダイレクト追従は付けず、ローカル確認ではプロキシを迂回します。

```sh
curl --noproxy '*' --fail --silent --show-error --max-time 5 \
  http://127.0.0.1:11434/api/status
curl --noproxy '*' --fail --silent --show-error --max-time 5 \
  http://127.0.0.1:11434/api/tags
lsof -nP -iTCP:11434 -sTCP:LISTEN
```

合格条件は `/api/status` の `cloud.disabled` がJSONの `true` で、待受が `127.0.0.1` または `::1` に限定されていることです。`*`、`0.0.0.0`、`[::]`、LANアドレスでの待受は修正します。APIが404、キーが不明、クラウド有効のままならOllamaのバージョン・設定・起動元を確認し、本文を使ったテストへ進みません。アプリ側の安全確認を削除して回避しないでください。

**ログアウト・再ログイン後にも** `brew services list`、上のAPIチェック、`lsof` を再実行し、自動起動・クラウド無効・ループバック待受が維持されることを確認します。未実施なら「再ログイン後は未確認」と記録します。GUIのログイン項目等が残って二重起動していないことも確認してください。

設定の根拠: [Ollama公式FAQ](https://docs.ollama.com/faq)。このアプリ自身も、各翻訳リクエストとチャット開始前にクラウド無効とローカルモデルを確認します。

## 4. ローカルモデルを準備する（この段階はオンライン）

既存モデルは `ollama list` と `/api/tags` で確認し、同名のモデルを勝手に上書きしません。モデル項目に `remote_host` / `remote_model` があるもの、`:cloud` / `-cloud` 名のものは使用しません。単にローカルのOllamaにつながることだけでは、モデルがローカルである証明になりません。

### 翻訳（標準）: TranslateGemma 12B

[Google公式モデル](https://huggingface.co/google/translategemma-12b-it)と[Gemma利用規約](https://ai.google.dev/gemma/terms)を確認してください。商用利用可能ですが、MITではなく独自規約です。禁止用途、再配布・サービス提供時の条件があり、会社の利用ルールも確認してください。

未導入の場合だけ[公式Ollama配布](https://ollama.com/library/translategemma:12b-it-q4_K_M)を取得します。

```sh
ollama pull translategemma:12b-it-q4_K_M
ollama list
```

約8.1GBのQ4_K_M版です。検証環境は24GiB Mac、Ollama 0.40.16です。アプリは専用の言語名・言語コード付き指示で訳を1つだけ要求し、周辺文脈やQwen整文は加えません。2Kコンテキスト内に収めるため480バイト以下に分割し、1024トークンの出力枠を確保します。出力上限に達した結果や、段落の一部だけの結果は保存せず要確認にします。

新規資料だけがこのモデルを既定にします。新規資料の原文言語は英語、翻訳先は日本語が既定です。必要なら原文を「自動判定」や別の言語へ変更できます。既存資料の保存済み言語・モデル・訳文・編集履歴・予約設定は変更しません。既存資料をGemmaへ切り替える場合は詳細設定で選び、訳文のリセット確認を行ってください。同じモデルでの「この資料の翻訳を再生成…」は確認後にキャッシュを使わず再生成し、失敗した文章の以前の訳文は保持します。

短文でも時期・期限の混同や、原文内の翻訳指示を訳せない例があります。出力を確認し、必要なら手修正してください。自動言語判定が難しい見出しや混在資料では原文言語を明示してください。

### 任意の旧モデル: CAT-Translate 1.4B（日英専用）

[CyberAgentの公式モデルとMITライセンス](https://huggingface.co/cyberagent/CAT-Translate-1.4b) を先に確認してください。商用利用の事前登録・売上上限はありません。次のレシピは [mmnga-oによるコミュニティGGUF変換版](https://huggingface.co/mmnga-o/CAT-Translate-1.4b-gguf) の固定リビジョンを使います。公式配布のGGUFではありません。会社の利用ルールで変換版の提供元も確認してください。ダウンロード済みでハッシュが一致すれば再取得は不要です。

```sh
curl --fail --location --proto '=https' --proto-redir '=https' \
  --output models/CAT-Translate-1.4b-Q4_K_M.gguf.partial \
  'https://huggingface.co/mmnga-o/CAT-Translate-1.4b-gguf/resolve/fe0ab30f267cd976a4f03d218defa6151af88b87/CAT-Translate-1.4b-Q4_K_M.gguf'

echo '546baf6bb2ddc5d70648edebdd7a4ed7ff76e10e340a2f69ccc9b43507275e07  models/CAT-Translate-1.4b-Q4_K_M.gguf.partial' | shasum -a 256 -c -
```

**ハッシュが `OK` の場合だけ** 次へ進めます。不一致なら登録せず、取得元とファイルを確認します。

```sh
mv models/CAT-Translate-1.4b-Q4_K_M.gguf.partial models/CAT-Translate-1.4b-Q4_K_M.gguf
ollama create cat-translate:1.4b -f models/Modelfile
```

Ollamaはモデルを自身の保存領域にも取り込みます。GGUFは約931MBなので、ダウンロードと登録で複数コピー分の空きを見込んでください。アプリは公式の日英翻訳指示をuserメッセージで送り、ModelfileでSarashinaのチャットテンプレートを適用します。CLIで試す場合も `Translate the following English text into Japanese.\n\nHello.` のように翻訳指示を付けます。Ollama 0.40.16で動作確認しています。

この任意の旧モデルやGGUFファイルを削除する必要はありません。既存のCAT資料はその設定を維持します。CATは日英専用で、短い見出しの自動判定や説明混入に限界があります。原文言語を明示し、出力を確認してください。

### チャット: Qwen

標準構成は [qwen3.5:4b](https://ollama.com/library/qwen3.5:4b) です。利用条件を確認し、未導入の場合だけ取得します。

```sh
ollama pull qwen3.5:4b
ollama list
```

他のローカル会話モデルも選べますが、TranslateGemma・CAT-Translate・PLaMoは翻訳専用なのでチャットには使いません。別モデルを選んだ場合は標準モデルでの確認と区別して記録します。モデルの取得に失敗した場合はオンラインで解決し、クラウドモデルへ切り替えて済ませないでください。

### 任意: 翻訳モデルを事前ロード

```sh
curl --noproxy '*' --fail --silent --show-error --max-time 120 \
  http://127.0.0.1:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"translategemma:12b-it-q4_K_M","keep_alive":-1,"stream":false}'
ollama ps
```

アプリは翻訳モデルに `keep_alive=-1`、会話モデルに30分を指定します。初回読み込み、Ollama再起動、メモリ不足による追い出しの後には再ロードが必要です。メモリを解放するときは、処理中でないことを確認して `ollama stop translategemma:12b-it-q4_K_M` を使います。

## 5. インストールへ進むための合格判定

ここまでで以下を確認し、結果を利用者へ示します。未確認を合格扱いにしないでください。

- [ ] macOS 14以降・Apple Silicon・対応SDKでビルドできる環境がある。
- [ ] モデルと資料用のディスク・メモリに余裕がある。
- [ ] Ollamaの `cloud.disabled == true` をAPIで確認した。
- [ ] 11434番の待受はループバックのみである。
- [ ] 翻訳モデルと会話モデルがローカルに保存され、アプリから使える名前で存在する。
- [ ] プレビューを使う場合は、LibreOfficeが `/Applications` にあり初回起動を完了した。導入を省略する場合は、読み込み・翻訳・保存・質問は使えるが、スライド画像のプレビューは使えないことを利用者に明示した。
- [ ] 既存アプリ・データの有無を確認し、更新なら保存・終了・バックアップを済ませた。

翻訳・チャット・プレビューを全部使う構成ではLibreOfficeも必須です。プレビューを省略する構成ではLibreOffice以外の必要条件がそろえば次に進めます。

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

**ビルドとインストールは別です。** 更新後は、実際の起動先 `/Applications/Slide Local.app` の `Info.plist` のバージョン・buildと、`Contents/MacOS/SlideLocal` のSHA256がビルドしたバンドルと一致することを確認してください。作業フォルダ内のアプリだけを検証して更新完了としないでください。保存済みの訳文はアプリ更新だけでは変わらないため、新しい翻訳処理を適用するには「この資料の翻訳を再生成…」を実行します。

Dockのアイコンを右クリックし、「オプション」→「Dockに追加／Dockに保持」を選びます。登録先がApplications内のアプリであることを確認し、ビルドフォルダ側のアイコンと取り違えないようにします。

## 7. 架空の資料で受け入れ確認する

実際の業務資料をエージェントへ渡す必要はありません。短い架空のPPTXを2つ用意します。たとえば「Revenue increased by 20%.」と「The meeting is next Monday.」を、それぞれ1スライドに入れます。

1. Dockから起動し、Ollama接続・ローカルモデル選択を確認します。
2. Finderから架空の.pptxをドロップし、進捗が表示されて文章表示で開くことを確認します。「PowerPointを開く…」からの読み込みも試します。一括翻訳の確認では2資料を同時に取り込み、「翻訳の進行状況」からまとめて予約し、1件ずつ処理して完了することを確認します。一時停止中の予約は再開まで始まらないことも確認します。
3. 訳文を修正し、「翻訳したPowerPointを保存…」で書き出します。PowerPoint等で再び開き、文字を編集できることを確認します。アプリ内への訳文保存と、ファイルへの書き出しは別です。
4. 会話モデルで「売上は何パーセント増えましたか？」と質問し、資料を参照した回答と会話保存を確認します。
5. ここまでの起動・読み込み・翻訳・保存・質問で、Slide LocalがLibreOfficeを起動していないことを確認します。プレビューを導入した場合だけ「スライド画像を確認」へ切り替え、原本／翻訳後を選んで「プレビューを作成・更新」を押し、この操作で初めて画像が作成されることを確認します。訳文の変更で画像が古いと案内され、更新すると反映されることも確認します。プレビュー未導入の場合はこの作成確認を省略し、未導入と記録します。
6. 別の資料を選ぶと文章表示に戻り、プレビューが自動作成されないことを確認します。アプリを終了・再起動し、資料・訳文・会話が残ることも確認します。

オフライン確認では、ダウンロードをすべて済ませ、利用者が他の作業への影響を確認してからインターネット経路を切断します。ループバックとOllamaは維持し、上の翻訳・チャット・プレビューをもう一度確認します。検証後は元の接続状態へ戻します。確認していない機能を「オフライン動作確認済み」と報告しないでください。

AIエージェントがクラウド型の場合、Macを完全に切断するとエージェント自体が操作できなくなる場合があります。その場合は利用者がこの手順を実行するか、[開発用の通信制限付き検証](tests/README.md#optional-offline-integration) を使い、検証方法の違いを記録します。ネットワーク制限を外して結果を合格にしないでください。

## 8. 記録と困ったとき

導入結果にはOS・CPU、ソフトのバージョン、モデル名、クラウド無効・待受の確認、配置場所、翻訳／保存／チャット／プレビュー／オフラインの各結果を記録します。個人の絶対パス、資料名、本文、会話、認証情報を公開Issueへ貼り付けないでください。

| 症状 | 確認すること |
| --- | --- |
| Ollama未接続 | CLI標準構成では `brew services list` と `brew services start ollama`、11434番の待受を確認して「接続・モデルを確認」。既存GUI構成ではGUIを手動起動。別構成と二重起動しない |
| クラウド無効状態を確認できない | `/api/status`、Ollamaの更新、JSONと実際の起動環境、再起動 |
| モデルが選べない | `/api/tags` の保存済みモデル名、remote項目、取得完了。チャットでTranslateGemma・CAT-Translate・PLaMoは表示しない |
| ドロップしても資料を読み込めない | ファイルの場所の取得中は進捗を表示し、取得できなければ15秒で待機を打ち切って案内します。「PowerPointを開く…」からFinderにある.pptxを選び直してください。この15秒はファイルの場所の取得期限で、資料全体の読み込み時間の上限ではありません |
| プレビュー失敗 | LibreOfficeの配置・初回起動、フォント、OSの描画制限。制限なしでの再実行はしない |
| ビルド失敗 | Apple Siliconネイティブ環境、選択中のSwift/SDK、空きディスク |
| 二重起動／更新時の問題 | 旧アプリの終了、同じApplication Supportへの書き込み競合 |
| ディスクやメモリ不足 | モデル・資料・出力・プレビューの容量、他アプリ、キューの件数 |

アプリを削除してもApplication SupportとOllamaモデルは自動削除されません。資料や会話を消す操作は、利用者がバックアップと対象を確認してから別途行ってください。
