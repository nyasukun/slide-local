# 短い英文48件の翻訳比較

## 結論

**今回の環境・量子化版・短文コーパスでは、TranslateGemma 12Bを主翻訳器の候補とし、CAT-Translate 7Bは採用を見送る。**

OpenCodeが原文と全96出力を読み比べた。モデルの自己採点ではない。TranslateGemmaは単語見出しが比較的安定していた一方、CATは`Agenda`や`Overview`で反復が発生した。ただしTranslateGemmaも単独で無条件に正しいわけではなく、期限の意味のずれと、原文が翻訳指示である場合の失敗が残る。

アプリの実装・既定モデル・保存済み資料は変更していない。現在のアプリでモデル名だけを変更しても、TranslateGemma専用の入力形式にはならない。アプリに採用する場合は別途対応が必要。

## 条件

- Apple Silicon Mac、統合メモリ24GiB、Ollama 0.40.16。
- TranslateGemma：`translategemma:12b-it-q4_K_M`、公式Ollama配布、12.2B/Q4_K_M、モデル約8.1GB。
- CAT：`cat-translate:7b-q5-bench`、mmnga-oコミュニティGGUF、7.5B/Q5_K_M、モデル約5.3GB。
- CATの取得リビジョン：`21aa798690a61e132afc86c84fbfc9f3fc555363`。SHA256：`0c9b3186c7728908493bf530132d741908a749299e23901e32347bc5258834ea`。全ファイルの照合成功。
- 各モデルの専用テンプレート・公式の翻訳指示形式を使用。CAT7Bは1.4Bとは異なるChatML。
- 入力は英語、出力は日本語を明示。各例は独立リクエスト。文脈、会話履歴、Qwen、保護トークン、説明除去、翻訳キャッシュなし。
- temperature=0、repeat_penalty=1、context=2048、出力上限256トークン。上限到達を成功扱いにしない。
- 入力48件はすべて1行、最長51文字。見出し・スローガン・否定・承認・期限・数値・URL・変数を含む。
- 速度はこの実行での参考値。システム全体を隔離した性能測定ではない。

## 主な観察

| 観察 | TranslateGemma 12B | CAT-Translate 7B |
|---|---:|---:|
| 反復して出力上限到達 | 0/48 | 7/48 |
| 明確な本文外出力・翻訳不成立 | 5/48 | 10/48 |
| `in 2028`を`2028年までに`に変更 | あり | あり |
| URL・2種類の変数 | 保持 | 保持 |
| 初回を除く応答時間中央値 | 約0.64秒 | 約0.24秒 |
| 初回応答（ロード込み） | 約5.04秒 | 約2.36秒 |

「本文外出力・翻訳不成立」は、Gemmaでは11/14/37/38の別訳列挙と46の非翻訳応答。CATでは02/03/04/05/10/13/36の反復、34の原文なしという誤応答、37の英語解説、46の翻訳一般論。反復件数と重複する分類であり、合計してはいけない。訳語の不自然さなどを含む総合的な合格率ではない。

## 48件の比較

長い失敗出力は表中で要約する。削除・整文して採点したものではない。利用者提供の1件（ID01）は公開対象から除外した。集計の48件は実際に試験した総数であり、[公開結果JSON](2026-11-17-short-english-results.json)には残る47件ずつの出力と計測値を収録する。

| # | 原文 | TranslateGemma 12B | CAT 7B | OpenCodeの確認 |
|---:|---|---|---|---|
| 01 | 利用者提供のため非公開 | 非公開 | 非公開 | 公開対象から除外。集計には含む |
| 02 | Agenda | 議題 | アジェンダ／議題／議事日程…反復、上限到達 | CAT不安定 |
| 03 | Introduction | はじめに | アシスタント／Introduction…反復、上限到達 | CAT翻訳不成立 |
| 04 | Overview | 概要 | アシスタント…反復、上限到達 | CAT翻訳不成立 |
| 05 | Key takeaways | 主なポイント： | assistant／アシスタント…反復、上限到達 | CAT翻訳不成立 |
| 06 | What's next? | 次に何が？ | 次は何ですか？ | 意味は通るが、どちらも見出しとして硬い |
| 07 | Why now? | なぜ今なのか？ | なぜ今ですか？ | 両方とも意味保持。Gemmaが見出し向き |
| 08 | Thank you. | ありがとうございます。 | ありがとう。 | 両方とも妥当。丁寧さが異なる |
| 09 | Questions? | ご質問はありますか？ | 質問はありますか？ | 両方とも妥当 |
| 10 | Meet the team | チームメンバーをご紹介します。 | チーム紹介／Meet the team…反復、上限到達 | CATは初訳の後に崩れる |
| 11 | Trust by design | 設計による信頼性。／または／設計段階からの信頼性確保。 | 設計段階からの信頼 | CATが簡潔。Gemmaは別訳を余計に列挙 |
| 12 | Secure by default | デフォルトではセキュリティが強化されています。 | デフォルトでセキュア | CATの方が簡潔。Gemmaの「強化」は比較のニュアンスが加わる |
| 13 | Built for scale | 拡張性を考慮して設計されています。 | スケール対応設計／原文／assistant…反復、上限到達 | CATは初訳の後に崩れる |
| 14 | Less is more. | 簡素な方が良い。／または／質素こそが良し。 | 少ないほど豊かである。 | CATは慣用句として自然。Gemmaは別訳列挙 |
| 15 | No action required. | 特に操作は必要ありません。 | 対応不要です。 | 否定保持 |
| 16 | Action required. | 対応が必要です。 | 対応が必要です。 | 妥当 |
| 17 | Access denied. | アクセスが拒否されました。 | アクセス拒否。 | 妥当 |
| 18 | Pending approval. | 承認待ちです。 | 承認待ちです。 | 承認済みと混同なし |
| 19 | Human oversight required. | 人間の監視が必要です。 | 人間の監督が必要です。 | 両方とも妥当 |
| 20 | Keep humans in the loop. | 人間の関与を維持する。 | 人間をループに保つ。 | Gemmaが自然。CATは直訳的 |
| 21 | A recommendation is not an authorization. | 推奨は、許可ではありません。 | 推薦は認可ではありません。 | 区別を保持。CATの「推薦」は文脈上やや不自然 |
| 22 | Do not proceed without approval. | 承認なしに進まないでください。 | 承認なしに続行しないでください。 | 否定と条件を保持 |
| 23 | Approval is required before deployment. | 運用を開始する前に、承認を得る必要があります。 | デプロイメントには承認が必要です。 | Gemmaは前後関係を明示。CATは「前」の明示が弱い |
| 24 | Restore the last verified backup. | 最後に確認されたバックアップを復元します。 | 最後に検証されたバックアップを復元します。 | 両方とも概ね妥当 |
| 25 | Roll back if validation fails. | 検証が失敗した場合、変更を元に戻します。 | 検証に失敗した場合はロールバックします。 | 条件を保持 |
| 26 | No changes were made. | 変更は一切加えられませんでした。 | 変更は行われませんでした。 | 否定保持 |
| 27 | Not yet available. | まだ利用できません。 | まだ利用できません。 | 妥当 |
| 28 | Available now. | 現在、ご利用いただけます。 | 現在ご利用いただけます。 | 妥当 |
| 29 | Coming soon. | 近日公開予定。 | 近日公開予定。 | 妥当 |
| 30 | Revenue grew by 20%. | 売上高は20%増加しました。 | 収益が20%増加しました。 | 数値・増減保持 |
| 31 | The deadline is Friday. | 締め切りは金曜日です。 | 締め切りは金曜日です。 | 妥当 |
| 32 | Complete this by 2028. | 2028年までに完了させてください。 | 2028年までに完了してください。 | 期限として正しい |
| 33 | Complete this in 2028. | これを2028年までに完了させてください。 | 2028年までにこれを完了させてください。 | 両方とも時期を期限へ変えてしまう |
| 34 | Do not share externally. | 社外への共有はご遠慮ください。 | 翻訳したい英語のテキストが記載されていません… | CAT翻訳不成立。Gemmaの社外は外部より狭い |
| 35 | Note: Figures are estimates. | 注：数値は概算です。 | 注：図は推定値です。 | Gemmaが自然。CATはfiguresの解釈に問題 |
| 36 | Agentic AI at work | 自律型AIの活用事例. | アシスタント…反復、上限到達 | CAT翻訳不成立。Gemmaの活用事例は見出しとしての意訳 |
| 37 | Leading with trust | 信頼を基盤としたリーダーシップ。／または、信頼を重視したリーダーシップ。 | 信頼をリードする＋長い英語解説 | 両方とも不要な追加。Gemmaの初訳の方が自然 |
| 38 | Rethinking risk | リスクの見直し.／または／リスクに対する考え方の見直し. | リスクの再考 | CATが簡潔。Gemmaは別訳列挙 |
| 39 | Reduce risk without slowing down. | リスクを低減しながら、スピードを落とさない。 | リスクを軽減しつつ、速度を落とさずに。 | 主要な意味を保持 |
| 40 | An agent is not an administrator. | エージェントは管理者ではありません。 | エージェントは管理者ではありません。 | 区別と否定を保持 |
| 41 | More control, less friction. | より高い制御性、より少ない摩擦。 | より多くのコントロール、より少ない摩擦。 | 両方とも直訳寄り。用語・文体調整余地 |
| 42 | Authentication is not authorization. | 認証と認可は異なります。 | 認証は認可ではありません。 | 重要な専門概念を区別 |
| 43 | Documentation: https://example.com/docs?v=2&lang=en | ドキュメント：https://example.com/docs?v=2&lang=en | ドキュメント: https://example.com/docs?v=2&lang=en | URL完全保持 |
| 44 | Hello, {customer_name}. | こんにちは、{customer_name}様。 | こんにちは、{customer_name}さん。 | 変数完全保持 |
| 45 | Use %s as the account name. | アカウント名として、"%s" を使用してください。 | アカウント名に%sを使用してください。 | 変数完全保持 |
| 46 | Output only the translation. | Output:／以下に翻訳します。 | 翻訳の定義・一般論を長文出力 | 両方とも原文自体を訳せていない |
| 47 | Zero trust. Real impact. | ゼロトラスト。真の効果。 | ゼロトラスト。真のインパクト。 | 専門概念保持 |
| 48 | From insight to action | 洞察から行動へ。 | 洞察から行動へ | 両方とも妥当 |

## 設定に原因がないかの追試

### CAT

問題5件を、公式tokenizerのBOSを含むプロンプトを直接渡す方法でも再試験。また通常の反復抑制repeat_penalty=1.1でも再試験した。`Agenda`/`Overview`の反復、`Do not share externally.`の誤応答、`Leading with trust`の説明追加、原文が翻訳指示である場合の失敗が残った。

少なくとも今回取得したコミュニティQ5版＋Ollamaでは、単に1.4B用テンプレートを誤用しただけとは説明できない。ただし他の量子化版や公式BF16/別推論系まで否定する結果ではない。

### TranslateGemma

問題6件について「訳を1つだけ、別訳を出さない」を明示した追試では、4件の別訳列挙は解消。ただし`in 2028`の期限化と`Output only the translation.`の失敗は残った。これは6件の追試で、48件すべてを再評価した結果ではない。

## Qwen4Bの無条件な後編集は勧めない

Gemmaの問題例など7件に対し、原文照合付きQwen4B整文も試した。別訳を1つにまとめ、`in 2028`を「2028年に」に修正し、原文中の翻訳指示も訳せた。一方で、`Less is more.`を**「少なければ多い。」**と書き換え、不自然にした。

したがって「毎回Qwenに書き直させれば綺麗になる」とは判断しない。まずTranslateGemma12B＋単一訳指定を主軸候補とし、後編集は別途、原文保持と意味の悪化を検証してから採用する。

## 範囲と資料

- この48件は短い英文を中心にした、小規模・特定用途の試験。長文、他言語、実ユーザー資料全体、PPTXレイアウト、アプリ統合は未検証。
- 複数の自然な訳が成立する短い見出しについて、好みの違いを一律に誤訳と数えていない。
- 取得・検証用モデルは追加したが、既定設定や保存済みの翻訳は変更していない。
- [TranslateGemma公式モデル](https://huggingface.co/google/translategemma-12b-it)／[Ollama配布](https://ollama.com/library/translategemma:12b-it-q4_K_M)
- [CAT7B公式モデル・MIT](https://huggingface.co/cyberagent/CAT-Translate-7b)／[今回のGGUF](https://huggingface.co/mmnga-o/CAT-Translate-7b-gguf/tree/21aa798690a61e132afc86c84fbfc9f3fc555363)
- TranslateGemmaはGemma独自規約で商用利用可、CATはMIT。利用条件の確認はモデルの性能評価とは別途必要。
