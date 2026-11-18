import SwiftUI

func languageName(_ code: String) -> String { languages.first { $0.0 == code }?.1 ?? (code.isEmpty ? "自動判定" : code) }
func settingsSummary(_ options: QueueOptions) -> String {
    "\(languageName(options.source)) → \(languageName(options.target)) · \(options.model)" +
    (options.notes ? " · 発表者ノートを含む" : " · 発表者ノートを除く") +
    (options.fit ? " · 文字サイズ自動調整あり" : " · 文字サイズ自動調整なし")
}

struct WorkflowHeader: View {
    @EnvironmentObject var studio: StudioModel
    var body: some View {
        if let p = studio.project {
            let phase = TranslationPolicy.phase(project: p, options: studio.currentOptions)
            HStack(spacing: 8) {
                step("1 資料を開く", active: false)
                Image(systemName: "chevron.right")
                step("2 翻訳する", active: phase != .complete)
                Image(systemName: "chevron.right")
                step("3 確認・修正", active: phase == .complete)
                Image(systemName: "chevron.right")
                step("4 保存する", active: phase == .complete)
                Spacer(minLength: 0)
            }.font(.callout).foregroundStyle(.secondary).accessibilityElement(children: .combine)
        }
    }
    private func step(_ title: String, active: Bool) -> some View {
        Text(title).fontWeight(active ? .semibold : .regular).foregroundStyle(active ? accent : .secondary)
    }
}

struct TranslationActionCard: View {
    @EnvironmentObject var studio: StudioModel
    var body: some View {
        if let p = studio.project {
            let phase = TranslationPolicy.phase(project: p, options: studio.currentOptions)
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    Label(heading(phase), systemImage: phase == .complete ? "checkmark.circle" : "character.book.closed")
                        .font(.headline)
                    if phase == .ready || phase == .settingsChanged { settings }
                    else if phase != .queued && phase != .running {
                        DisclosureGroup("翻訳設定を確認・変更", isExpanded: $studio.showTranslationSettings) { settings.padding(.top, 12) }
                    }
                    if phase == .running || phase == .queued { activeStatus(p) }
                    else if phase == .complete {
                        Text(p.units.isEmpty ? "翻訳対象の文章はありません。画像などを保持したPowerPointを保存できます。" : "訳文はアプリ内に保存済みです。下で確認・修正し、保存先を選んでください。")
                            .font(.callout)
                        exportAction
                    } else {
                        if phase == .review {
                            Text(p.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if studio.settingsChanged { settingsImpact(p) }
                        waitingHint
                        Button(action: studio.translate) {
                            Label(TranslationPolicy.actionTitle(project: p, options: studio.currentOptions, paused: studio.queuePaused), systemImage: "character.bubble")
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(studio.translationBlockReason != nil)
                        if let reason = studio.translationBlockReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                        Text("対象の文章を翻訳します。画像内の文字・数式・スライドマスターの文字は原文のままです。")
                            .font(.callout).foregroundStyle(.secondary)
                        if let reason = studio.exportBlockReason { Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
                        else { exportAction }
                    }
                    if phase != .queued && phase != .running && !p.units.isEmpty {
                        Button("この資料の翻訳を再生成…", action: studio.regenerateTranslation)
                            .disabled(studio.translationBlockReason != nil)
                        Text("キャッシュを使わず、現在の対象文章を翻訳し直します。手修正を含む訳文の置き換え前に確認します。").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func heading(_ phase: WorkflowPhase) -> String {
        switch phase {
        case .ready: return "この資料を翻訳する"
        case .queued: return "翻訳の順番を待っています"
        case .running: return "翻訳しています"
        case .review: return "未完了の文章を確認"
        case .complete: return "翻訳を確認して保存"
        case .settingsChanged: return "翻訳設定を反映する"
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("原文の言語", selection: $studio.source) {
                    Text("自動判定").tag("")
                    if !studio.source.isEmpty && !studio.translationLanguages.contains(where: { $0.0 == studio.source }) {
                        Text("\(studio.source)（このモデルでは非対応）").tag(studio.source)
                    }
                    ForEach(studio.translationLanguages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Image(systemName: "arrow.right").accessibilityHidden(true)
                Picker("翻訳する言語", selection: $studio.target) {
                    if !studio.translationLanguages.contains(where: { $0.0 == studio.target }) {
                        Text("\(studio.target)（このモデルでは非対応）").tag(studio.target)
                    }
                    ForEach(studio.translationLanguages, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            if LocalModel.isCATTranslation(studio.translationModel) {
                Text("CAT-Translateは日英専用です。短文・固有名詞で自動判定が難しい場合は、原文の言語を指定してください。").font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("詳細設定：モデル・発表者ノート・文字サイズ") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("翻訳用モデル", selection: $studio.translationModel) {
                        if !studio.models.contains(where: { $0.name == studio.translationModel }) {
                            Text(studio.translationModel.isEmpty ? "利用できるモデルがありません" : "\(studio.translationModel)（利用不可）").tag(studio.translationModel)
                        }
                        ForEach(studio.models) { Text($0.name).tag($0.name) }
                    }
                    Toggle("発表者ノートも翻訳・保存の対象にする", isOn: $studio.notes)
                    Toggle("PowerPoint保存時に文字サイズを自動調整する", isOn: $studio.fit)
                    Text("文字の収まりはPowerPointで確認してください。ノートを外しても、保存済みのノート訳文はアプリ内に残ります。")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }.font(.callout)
        }.disabled(studio.translating || studio.controlsLocked)
    }
    @ViewBuilder private func settingsImpact(_ p: Project) -> some View {
        if TranslationPolicy.changesLanguageOrModel(p, studio.currentOptions), p.units.contains(where: { !$0.translation.isEmpty }) {
            Label("言語・モデルを変えると、手修正と対象外のノートを含む現在の訳文を消して翻訳し直します。実行前に確認します。", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
        } else if !TranslationPolicy.changesLanguageOrModel(p, studio.currentOptions) {
            Text("訳文を保持し、未翻訳の対象文章だけを翻訳します。文字サイズの変更だけでも、順番待ち・モデル確認とPowerPoint作成が必要です。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var waitingHint: some View {
        if studio.queuePaused {
            Label("翻訳は一時停止中です。予約後に「翻訳の進行状況」から再開してください。", systemImage: "pause.circle")
                .font(.callout).foregroundStyle(.orange)
            Button("翻訳の進行状況を開く") { studio.showProgress = true }.buttonStyle(.link)
        } else if studio.queueItems.contains(where: { ["queued", "running"].contains($0.status) }) {
            Text("先に予約された資料が終わり次第、翻訳します。").font(.callout).foregroundStyle(.secondary)
        }
    }
    private func activeStatus(_ p: Project) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settingsSummary(studio.currentQueueItem?.options ?? TranslationPolicy.options(p))).font(.callout).foregroundStyle(.secondary)
            if let item = studio.currentQueueItem {
                Text(TranslationPolicy.queueStatusTitle(item, paused: studio.queuePaused)).fontWeight(.medium)
                if item.status == "running", let completed = item.completed, let total = item.total, total > 0 {
                    ProgressView(value: Double(completed), total: Double(total))
                        .accessibilityLabel("翻訳した文章").accessibilityValue("\(completed) / \(total)")
                    Text("完了した文章 \(completed) / \(total)（原文を保持した文章を含む）").font(.callout)
                }
                Button(item.status == "queued" ? "この資料の翻訳予約を取り消す" : "この資料の翻訳を停止", action: studio.cancelTranslation)
                    .disabled(studio.actionBusy || item.cancel_requested == true)
                Text(item.status == "queued" ? (studio.queuePaused ? "再開するまで翻訳は始まりません。" : "先に予約された資料が終わると始まります。") : "停止は現在のリクエストが終わるまで待つ場合があります。完了した訳文は保持します。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("翻訳の進行状況を開く") { studio.showProgress = true }.buttonStyle(.link)
        }
    }
    private var exportAction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: studio.exportPPTX) { Label("翻訳したPowerPointを保存…", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!studio.canExport)
            if let reason = studio.exportBlockReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

struct TranslationConfirmationSheet: View {
    @EnvironmentObject var studio: StudioModel
    let request: TranslationRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(request.regenerate ? "キャッシュを使わず翻訳を再生成しますか？" : "現在の訳文を消して翻訳し直しますか？", systemImage: "exclamationmark.triangle").font(.title2)
            if request.regenerate {
                Text("現在の対象文章を再生成し、手修正を含む訳文を成功した文章から置き換えます。同じ言語・モデルなら失敗した文章の以前の訳文は保持し、要確認にします。言語・モデルも変更する場合は、対象外ノートを含む既存訳文を消して処理します。この操作は取り消せません。")
            } else {
                Text("下記の対象には、手動修正と翻訳対象から外したノートの訳文も含まれます。この操作は取り消せません。")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("適用する設定").font(.headline)
                    Text(settingsSummary(request.options)).textSelection(.enabled)
                    ForEach(request.assessments, id: \.projectID) { assessment in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(assessment.filename).fontWeight(.medium).textSelection(.enabled)
                            Text("資料ID \(assessment.projectID.prefix(8)) · " + (assessment.resetsTranslations ? "\(assessment.translatedCount)件の訳文を\(request.regenerate ? "置換" : "消去")" : "既存訳文の消去なし"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 100, maxHeight: 320)
            Text("先に保存した編集内容は、キャンセルしてもアプリ内に残ります。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("キャンセル") { studio.dismissTranslation(request) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.regenerate ? "翻訳の再生成を予約する" : "訳文を消して翻訳を予約する", role: .destructive) { studio.confirmTranslation(request) }
            }
        }.padding(26).frame(width: 600).interactiveDismissDisabled()
    }
}

struct TranslationProgressSheet: View {
    @EnvironmentObject var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    private var confirmation: Binding<TranslationRequest?> {
        Binding(get: { studio.pendingTranslation }, set: { value in if value == nil, let request = studio.pendingTranslation { studio.dismissTranslation(request) } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("翻訳の進行状況").font(.title2.bold()); Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction).disabled(studio.actionBusy) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = studio.queueError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("予約状態の保存を再試行して翻訳を再開") { studio.setQueuePaused(false) }.disabled(studio.controlsLocked)
                    }
                    HStack {
                        Text(studio.queuePaused ? "次の資料から一時停止中" : "追加順に1件ずつ翻訳")
                        Spacer()
                        Button(studio.queuePaused ? "順番待ちの翻訳を再開" : "次の資料から一時停止") { studio.setQueuePaused(!studio.queuePaused) }.disabled(studio.controlsLocked)
                    }
                    Text("一時停止しても、処理中の資料は最後まで翻訳します。資料ごとに停止する場合は、各資料の「翻訳を停止」を使ってください。")
                        .font(.callout).foregroundStyle(.secondary)
                    if !studio.pendingBatchIDs.isEmpty { batchPanel }
                    Divider()
                    if studio.queueItems.isEmpty { Text("翻訳の予約はありません。資料の画面で「この資料を翻訳する」を押すと、ここに進行状況が表示されます。").foregroundStyle(.secondary) }
                    ForEach(studio.queueItems) { item in queueRow(item) }
                    if !studio.completedQueueItems.isEmpty {
                        Divider()
                        Text("まとめて保存：\(studio.completedQueueItems.count)件").font(.headline)
                        ForEach(studio.completedQueueItems) { item in Text("• \(item.filename) · \(item.project_id.prefix(8))").font(.callout) }
                        Text("各資料の最新の翻訳履歴が「翻訳完了」のものが対象です。手編集で修復しても最新履歴が要確認なら対象外です。その場合は資料を開いて個別に保存できます。編集中の訳文を先に保存し、未反映の画面設定は適用せず、各資料の保存済み設定で書き出します。同名ファイルは連番にします。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("完了した\(studio.completedQueueItems.count)件の保存先フォルダを選ぶ…", action: studio.exportCompletedQueue).disabled(studio.controlsLocked)
                    }
                    Divider()
                    Text("ウィンドウを閉じてもアプリ実行中は翻訳を続けます。アプリ終了時は中断し、次回に未完了分を復元します。確認が必要な資料は保留され、一時停止の設定も維持します。Macのスリープ中は進みません。")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.trailing, 8)
            }
        }.padding(24).frame(minWidth: 650, idealWidth: 760, maxWidth: 850, minHeight: 420, idealHeight: 620, maxHeight: 680)
            .sheet(item: confirmation) { request in TranslationConfirmationSheet(request: request).environmentObject(studio) }
            .interactiveDismissDisabled(studio.actionBusy)
    }
    private var batchPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("取り込んだ資料をまとめて翻訳").font(.headline)
                Text("対象 \(studio.pendingBatchIDs.count)件 · この設定を全件に適用").font(.callout)
                Text(settingsSummary(studio.currentOptions)).font(.callout)
                ForEach(studio.pendingBatchIDs, id: \.self) { id in
                    Text("• \(studio.projects.first { $0.id == id }?.filename ?? id) · \(id.prefix(8))").font(.callout)
                }
                Text("未予約の対象一覧はこの起動中だけ保持します。予約後の順番待ちは次回起動にも残ります。設定は資料の画面で変更できます。").font(.callout).foregroundStyle(.secondary)
                if studio.queuePaused { Label("一時停止中のため、再開するまで始まりません。", systemImage: "pause.circle").font(.callout) }
                Button(studio.queuePaused ? "\(studio.pendingBatchIDs.count)件の翻訳を予約する" : "\(studio.pendingBatchIDs.count)件をまとめて翻訳する", action: studio.enqueueBatch)
                    .buttonStyle(.borderedProminent).disabled(studio.translationBlockReason != nil)
                if let reason = studio.translationBlockReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
    private func queueRow(_ item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.filename).font(.headline).textSelection(.enabled)
                    Text("資料ID \(item.project_id.prefix(8)) · " + TranslationPolicy.queueStatusTitle(item, paused: studio.queuePaused)).font(.callout)
                }
                Spacer()
                Button("資料を開く") {
                    Task { do { try await studio.selectProject(item.project_id); if !studio.actionBusy { dismiss() } } catch { studio.error = error.localizedDescription } }
                }.disabled(studio.controlsLocked)
            }
            Text(settingsSummary(item.options)).font(.callout).foregroundStyle(.secondary)
            if let completed = item.completed, let total = item.total, total > 0 {
                Text("この実行で完了した文章 \(completed) / \(total)").font(.callout)
            }
            Text(item.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if ["queued", "running"].contains(item.status) {
                Button(item.status == "queued" ? "翻訳予約を取り消す" : "この資料の翻訳を停止") { studio.cancelQueue(item) }
                    .disabled(studio.controlsLocked || item.cancel_requested == true)
            } else if ["error", "review", "cancelled", "confirmation"].contains(item.status) {
                Text("再試行には上記の履歴設定を使います。現在の訳文が消える場合は確認します。").font(.callout).foregroundStyle(.secondary)
                Button(item.status == "confirmation" ? "設定と訳文を確認して予約し直す…" : "履歴の設定で未完了部分を再試行…") { studio.retryQueue(item) }
                    .disabled(studio.controlsLocked || studio.queueItems.contains { $0.project_id == item.project_id && ["queued", "running"].contains($0.status) })
            }
            Divider().padding(.vertical, 5)
        }
    }
}
