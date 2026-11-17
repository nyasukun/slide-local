# Translation UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 内部の永続逐次キューを維持し、資料を開く→翻訳→確認・修正→保存を明確にする。

**Architecture:** エンジンで翻訳要求の版確認と破壊的変更の許可を担保する。UIは対象・設定・ドラフトを固定して操作を直列化し、テスト可能な状態判断とSwiftUI表示を分ける。進行状況・一括処理はシートへ移す。

**Tech Stack:** Swift 5、SwiftUI/AppKit、macOS 14+、既存のSQLite/ZIP/PPTX処理、Pythonの架空資料テスト。

**Spec:** `docs/superpowers/specs/2026-11-17-translation-ux-design.md`

## Global Constraints

- SwiftUI/AppKitと既存ローカルエンジン、既存データとの読取互換性・ローカル通信保護を維持する。
- キューの永続化、追加順の逐次処理、一時停止・再開、取消・再試行、エラー後の後続継続、終了・再起動時の復元を維持する。
- 素材は架空の資料のみ。監査やレビューのために利用者の実資料を外部送信しない。
- 翻訳承認は正確な要求設定と資料の版に結び付ける。検証不能な破壊的要求は保留し後続を継続する。
- CLI化は別チャットが担当。こちらの完了後に統合し、GUI起動を前提とした実装を追加しない。
- 読み込み・翻訳では元ファイルは変更しない。書出しによる上書きは明示的に確認する。

## Review Focus

1. モデル確認のawait中の取消・資料変更：消去前に停止と版を再検証する（Task 1）。
2. 消去直後の終了と旧データの再起動：二重消去せず不明な承認は保留する（Task 1）。
3. 未保存編集・同名資料・二重操作：対象と編集を固定し誤送信や黙った欠落を防ぐ（Tasks 2–3）。
4. ゼロ文章・空白訳文・旧履歴・一括保存対象外：実際の保存条件と表示を一致させる（Tasks 2–4）。
5. 画像読込・回答完了の遅延：別資料や削除後の画面に古い結果を反映しない（Task 5）。

## File Map

- `NativeTypes.swift`：互換性のある予約承認・消去済み要求ID・種類別プレビュー情報。
- `NativeTranslationPolicy.swift`（新規）：設定差、内容fingerprint、要求評価、UI用状態判断。Foundationのみ。
- `NativeEngine.swift`：承認つき登録、実行時確認、停止、履歴進捗、生成物の安全性。
- `NativeApp.swift`：StudioModelの操作直列化と画面組立。既存のGUI起動箇所は触らない。
- `NativeWorkflowViews.swift`（新規）：翻訳・確認・進行状況シート等のSwiftUIコンポーネント。
- `tests/NativeUXSafetyTests.swift`（新規）：制御可能な推論を使う競合・停止・回復テスト。
- `tests/NativeUXPolicyTests.swift`（新規）：純粋な状態・文言・条件テスト。
- `tests/NativeStudioTests.swift`（新規）：StudioModelの対象固定・ドラフト・会話のテスト。
- `build-native.command`、`tests/run-native-tests.command`：新規ファイルのコンパイルとテスト登録。
- `README.md`、`tests/README.md`：利用手順・検証手順。

---

### Task 1: 永続キューの安全な翻訳承認

**Files:** `NativeTypes.swift`, new `NativeTranslationPolicy.swift`, `NativeEngine.swift`, new `tests/NativeUXSafetyTests.swift`, `build-native.command`, `tests/run-native-tests.command`.

**Interfaces:**
- `TranslationAssessment: Sendable`：`projectID: String`, `filename: String`, `fingerprint: String`, `resetsTranslations: Bool`, `translatedCount: Int`, `options: QueueOptions`。
- `TranslationPolicy.fingerprint(_ project: Project) throws -> String`：保存設定と全文章のID・原文・訳文・状態から安定したSHA256。会話・進捗・プレビューは除く。
- `NativeEngine.assessTranslation(_ ids: [String], options: QueueOptions) throws -> [TranslationAssessment]`：queued表示用overlayを使わない。
- `NativeEngine.enqueue(_ ids: [String], options: QueueOptions, assessments: [TranslationAssessment] = [], allowReset: Bool = false) async throws`：既存の非破壊的呼出しは互換、既存訳文の消去は承認必須。
- `QueueItem`に任意の`approved_fingerprint: String?`、`Project`に`translation_request_id: String?`を追加。既存JSONのdecodeを維持する。

- [ ] **1. RED:** 同設定再実行、未承認の言語変更拒否、ノート内手修正も確認対象、承認後編集で登録拒否、モデル確認中の停止で消去しない、旧破壊的予約の保留と後続継続、消去直後再起動で完了訳を二重消去しないテストを書く。
- [ ] **2. RED確認:** 専用テストを通常スイートに登録し`./tests/run-native-tests.command`を実行。未実装APIで失敗することを確認。
- [ ] **3. 実装:** 型・fingerprint・評価・登録を実装。モデル検証後の同一actor区間で照合／重複確認／保存。実行直前に停止と版を照合し、確認待ちは`confirmation`状態で後続へ。消去と要求IDは同じproject commit、復元は要求IDと設定を照合する。モデル消失時は消去前に失敗させる。
- [ ] **4. GREEN:** 全スイートで既存FIFO・停止・復元テストと新規安全テストがPASS。
- [ ] **5. Commit:** `feat: protect queued translation resets with durable approval`

### Task 2: 書出し・履歴・プレビューの正確性

**Files:** `NativeEngine.swift`, `NativeTypes.swift`, `NativeStore.swift`, `NativeTranslationPolicy.swift`, `tests/NativeUXSafetyTests.swift`, `tests/NativeUXPolicyTests.swift`.

**Interfaces:**
- `TranslationPolicy.exportBlockReason(project: Project, drafts: [String: String], options: QueueOptions, busy: Bool) -> String?`：nilならUI上保存可。空白ドラフト不可、ゼロ文章可。
- `NativeEngine.export(_ id: String) async throws -> URL`：呼出しごとに一意な完成PPTXを返す。UIは保存コピー後この一時生成物を削除する。既存の内部translated.pptxを使うプレビューとは区別する。
- `atomicSave(_ source: URL, to destination: URL, overwrite: Bool = true) throws`：一括はfalseで非上書き。競合時は再採番。
- `PreviewRecord: Codable, Sendable`：`state: String`, `fingerprint: String?`, `stamp: Double?`, `error: String?`。Projectに種類別の任意レコードを持つ。旧画像は新鮮とみなさず更新案内。

- [ ] **1. RED:** 過去履歴を現在の進捗で汚染しない、ゼロ文章保存、空白ドラフト無効、再生成しても先のexport URLの内容不変、非上書き保存で既存データ保持、プレビュー種類・版の判定テストを追加する。
- [ ] **2. RED確認:** `./tests/run-native-tests.command`で追加条件の失敗を確認する。
- [ ] **3. 実装:** 各実行の進捗を予約項目に保存しoverlayを撤去。export時に一意なPPTXを生成。プレビューの作成開始時の版を記録し、終了時に一致した場合だけreadyとする。翻訳中に生成した原本画像の状態も翻訳側の古いローカルコピーで上書きしない。
- [ ] **4. GREEN:** 全スイートPASS。source.pptxのhashと既存のプライバシーテストも不変。
- [ ] **5. Commit:** `fix: preserve accurate export history and preview revisions`

### Task 3: StudioModelの操作対象・ドラフト保護

**Files:** `NativeApp.swift`, `NativeTranslationPolicy.swift`, new `tests/NativeStudioTests.swift`, `tests/run-native-tests.command`.

**Interfaces:**
- `StudioModel`にテスト用の`init(engine: NativeEngine? = nil)`。テストビルド時は`#if !STUDIO_TESTS`で本番`@main`のみを除外。
- `TranslationRequest: Identifiable`：UUID、対象ID、設定、評価リスト。`@Published var pendingTranslation: TranslationRequest?`で確認を表示。
- `requestTranslation(ids: [String], options: QueueOptions)`、`confirmTranslation(_ request: TranslationRequest)`、`dismissTranslation(_ request: TranslationRequest)`：単体・一括・再試行共通。
- `saveDrafts(projectID: String, changes: [String: String]) async throws`：対象固定。UI更新は同じ資料かつ同じドラフト値の場合のみ削除。既存の引数なしメソッドは現在値のスナップショットを渡す。
- `@Published var actionBusy: Bool`：保存・選択・登録・書出し・プレビュー準備を直列化。確認中も資料・設定・編集変更を無効化する。

- [ ] **1. RED:** 単体／一括／旧設定再試行の確認表示、キャンセルで未登録、ドラフト保存失敗で登録なし、非対象資料の編集を保存しない、部分保存後の未保存内容保持、連打の重複防止、モデル欠如で自動置換しないテストを書く。
- [ ] **2. RED確認:** `./tests/run-native-tests.command`のStudioModel専用バイナリで失敗を確認する。
- [ ] **3. 実装:** すべての入口を対象固定の共通フローにする。確認前に固定したドラフトを保存・評価し、必要時だけ確認。複数取込の成功分だけbatchIDsに追加、成功登録分だけ除去。保存失敗時は未保存分を保持して結果を通知。一括対象はセッション内と明示する。pauseは明示Boolを送る。
- [ ] **4. GREEN:** Studioテストと全スイートPASS。
- [ ] **5. Commit:** `fix: bind studio actions to immutable document requests`

### Task 4: 資料中心の画面と全操作文言

**Files:** `NativeApp.swift`, new `NativeWorkflowViews.swift`, `NativeTranslationPolicy.swift`, `tests/NativeUXPolicyTests.swift`, `build-native.command`.

**Interfaces:**
- `WorkflowPhase`：`ready`, `queued`, `running`, `review`, `complete`, `settingsChanged`。`TranslationPolicy.phase(project: Project, options: QueueOptions) -> WorkflowPhase`。
- `TranslationPolicy.actionTitle(project: Project, options: QueueOptions, paused: Bool) -> String`：初回「この資料を翻訳する」、停止中「この資料の翻訳を予約する」、部分完了「未完了部分を翻訳する」、設定のみ「変更を反映する」、破壊的変更「設定を変えて翻訳し直す」。
- `TranslationProgressSheet`, `TranslationActionCard`, `WorkflowHeader`：既存StudioModelをEnvironmentObjectで利用するSwiftUI View。
- StudioModelに`showProgress`, `showChat`、詳細設定開閉状態を追加する。

- [ ] **1. RED:** 全phase・主ラベル、待機理由、保存不可理由、停止受付、確認待ち、モデルなし、ノート／fitだけの反映を網羅する純粋テストを追加する。
- [ ] **2. RED確認:** `./tests/run-native-tests.command`で未実装状態を確認する。
- [ ] **3. 実装:** 資料一覧／中央の手順と主操作／切替可能な質問欄を構成。キュー・一括処理はスクロール可能シートへ。一括対象名・ID・共通設定と保存対象条件を表示。確認ダイアログは対象全件を読める一覧にし、破壊的実行／キャンセルを分ける。全アイコンにhelp/accessibilityLabelを付け、補足は読みやすい標準サイズに揃える。
- [ ] **4. GREEN:** 全スイートと`./build-native.command --stage`が成功。1100×760で主操作・シート内全操作へアクセスできることを実機確認する。
- [ ] **5. Commit:** `feat: organize translation UX around the selected document`

### Task 5: 確認・プレビュー・会話・接続の期待値を整える

**Files:** `NativeApp.swift`, `NativeWorkflowViews.swift`, `NativeTranslationPolicy.swift`, `tests/NativeStudioTests.swift`, `tests/NativeUXPolicyTests.swift`.

**Interfaces:**
- `StudioModel.previewFreshness: String`：対象・種類・保存版・ドラフト・設定を比較する表示用説明。
- `@Published var pendingChatDeletion: ChatDeletionRequest?`：対象資料ID・会話世代・資料名を固定する。
- `confirmChatDeletion(_ request: ChatDeletionRequest)`：回答の停止と世代無効化の後に削除。遅延完了で履歴を復活させない。
- `StudioModel.chatBlockReason: String?`：空欄、6000 Unicode scalars超過、未接続、モデルなしを区別する。

- [ ] **1. RED:** ドラフトによるプレビュー陳腐化、種類／資料切替後の古い画像却下、削除後の遅延回答記録拒否、回答停止の非永続表示、6000/6001 scalar境界、モデル不在・一覧取得失敗時の文言テストを追加する。
- [ ] **2. RED確認:** `./tests/run-native-tests.command`で追加テストの失敗を確認する。
- [ ] **3. 実装:** プレビュー種類をawait前に固定し、key一致でのみ画像反映。原文／訳文の抜粋参照とノート除外、候補は入力のみ、未完了会話は保存しない旨を表示。会話削除を確認制にし、操作世代で送信・停止・削除・切替を整合させる。Ollama接続とモデル準備の違い、インストール手順、閉じる／終了の違いを案内する。
- [ ] **4. GREEN:** 全スイート・ステージビルド成功。実機で翻訳前／完了／プレビュー失敗／質問欄／削除確認を確認。VoiceOverとキーボード未検証なら明記する。
- [ ] **5. Commit:** `fix: clarify preview chat and connection interactions`

### Task 6: Terra全体レビュー、文書更新、CLI変更との統合

**Files:** `README.md`, `tests/README.md`, 全変更ファイル。CLI側は提供されたブランチ／コミットと変更内容を確認後に限定する。

**Interfaces:** Tasks 1–5の公開API・UI。CLI側の起動・再接続契約はその実装を正として確認する。

- [ ] **1. 文書:** 実際の画面ラベル、手動プレビュー作成、一括の対象・保存条件、待機・停止・再開、モデル不足、終了復元の説明を更新する。
- [ ] **2. 全体検証:** `./tests/run-native-tests.command`と`./build-native.command --stage`を実行し結果を記録する。通常スイートは実推論・GUIの代替ではないと明示する。
- [ ] **3. Terraレビュー:** `openai/gpt-6.1-terra`で設計・全差分・全操作・新旧JSON互換・競合テストをレビュー。Critical/Importantを修正し再実行・再レビューする。素材は架空資料のみ。
- [ ] **4. CLI変更の特定:** 別チャットのブランチ／コミット／作業状況を確認。未コミット作業を破棄しない。不明なら対象をユーザーに確認し、完了前に勝手に取り込まない。
- [ ] **5. 統合:** 対象コミットを明示した非破壊的mergeまたは合意したcherry-pick。NativeApp.swiftの起動と接続文言をCLI実装に合わせる。GUI用`open -a Ollama`を復活させない。競合は両方の意図を保持する。
- [ ] **6. 統合検証:** 全スイート・ステージビルドとTerra差分レビューを再実施。CLI起動／再接続／モデル不在／翻訳予約／再起動復元の実環境確認を可能な範囲で行い、未確認を明記する。
- [ ] **7. Commit:** `docs: document and verify the translation workflow`。統合は履歴に明示し、最後にユーザー指定の統合先へ反映する。mainの他作業を上書きしない。

## Plan self-review

設計の各項目をTasks 1–6へ対応付けた。FIFO・永続承認・ドラフト・停止・保存・履歴・プレビュー・会話・モデル・アクセシビリティ・文書・CLI統合を含む。新規API名と利用先を一致させた。モデル推論そのもの、ファイル形式の拡大、全面セキュリティ監査は対象外。実機環境がなければ検証済みとせず残課題を報告する。
