import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let pptxType = UTType(filenameExtension: "pptx") ?? .data
let accent = Color(red: 0.13, green: 0.43, blue: 0.33)
let canvas = Color(red: 0.97, green: 0.98, blue: 0.96)

struct TranslationRequest: Identifiable {
    let id = UUID()
    let ids: [String]
    let options: QueueOptions
    let assessments: [TranslationAssessment]
}
struct ChatDeletionRequest: Identifiable {
    let id = UUID()
    let projectID: String
    let filename: String
    let generation: String
}

@MainActor final class StudioModel: ObservableObject {
    @Published var projects: [ProjectItem] = []
    @Published var project: Project?
    @Published var models: [LocalModel] = []
    @Published var connected = false
    @Published var starting = true
    @Published var working = false
    @Published var error: String?
    @Published var notice = ""
    @Published var slide = 1
    @Published var source = ""
    @Published var target = "ja"
    @Published var translationModel = "plamo-translate:0.8b"
    @Published var chatModel = "qwen3.5:4b"
    @Published var notes = false
    @Published var fit = true
    @Published var preview = false
    @Published var translatedPreview = false
    @Published var previewImage: NSImage?
    @Published var drafts: [String: String] = [:]
    @Published var chatInput = ""
    @Published var useDocument = true
    @Published var currentSlideOnly = false
    @Published var bubbles: [ChatBubble] = []
    @Published var chatting = false
    @Published var chatFinalizing = false
    @Published var dropTarget = false
    @Published var queueItems: [QueueItem] = []
    @Published var queuePaused = false
    @Published var batchIDs: [String] = []
    @Published var enqueueing = false
    @Published var actionBusy = false
    @Published var pendingTranslation: TranslationRequest?
    @Published var showProgress = false
    @Published var showChat = true
    @Published var showTranslationSettings = false
    @Published var queueError: String?
    @Published var pendingChatDeletion: ChatDeletionRequest?
    private var engine: NativeEngine?
    private var updatesTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var chatGeneration = UUID()
    private var selectionGeneration = UUID()
    private var previewKey = ""
    init(engine: NativeEngine? = nil) { self.engine = engine; if engine != nil { starting = false } }
    var controlsLocked: Bool { starting || working || actionBusy }
    var currentOptions: QueueOptions { QueueOptions(target: target, source: source, model: translationModel, notes: notes, fit: fit) }
    var currentQueueItem: QueueItem? { queueItems.first { $0.project_id == project?.id && ["queued", "running"].contains($0.status) } }
    var translationBlockReason: String? {
        if controlsLocked { return "現在の操作が終わるまでお待ちください。" }
        if !connected { return "Ollamaに接続できません。「接続・モデルを確認」から再確認してください。" }
        if !models.contains(where: { $0.name == translationModel }) { return "選択した翻訳モデルがこのMacにありません。詳細設定でモデルを選び直してください。" }
        return nil
    }
    var completedQueueItems: [QueueItem] {
        queueItems.filter { item in item.status == "complete" && queueItems.last(where: { $0.project_id == item.project_id })?.id == item.id }
    }
    var chatInputCount: Int { chatInput.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count }
    var chatBlockReason: String? {
        if controlsLocked { return "現在の操作が終わるまでお待ちください。" }
        if !connected { return "Ollamaに接続できません。接続・モデルを確認してください。" }
        if !chatModels.contains(where: { $0.name == chatModel }) { return "このMacで利用できる質問用モデルを選んでください。" }
        if chatInputCount == 0 { return "質問を入力してください。" }
        if chatInputCount > 6000 { return "質問は6000文字単位以内にしてください。絵文字などは複数として数えます。" }
        return nil
    }
    var previewFreshness: String {
        guard let p = project else { return "資料を開いてください。" }
        let record = translatedPreview ? p.translated_preview : p.source_preview
        if p.preview_state == "rendering", record?.state == "rendering" { return "プレビューを作成しています。" }
        if record?.state == "error" { return record?.error ?? "プレビュー作成に失敗しました。再作成できます。" }
        if TranslationPolicy.previewIsFresh(p, translated: translatedPreview, hasDrafts: !drafts.isEmpty, options: currentOptions) { return "最新の保存内容を表示しています。" }
        if translatedPreview, !drafts.isEmpty || settingsChanged { return "訳文・設定の変更は画像に未反映です。変更を保存・反映してからプレビューを更新してください。" }
        return "プレビューが未作成、または古い状態です。「プレビューを作成・更新」を押してください。"
    }
    var exportBlockReason: String? {
        guard let project else { return "PowerPointを開いてください。" }
        return TranslationPolicy.exportBlockReason(project: project, drafts: drafts, options: currentOptions, busy: controlsLocked)
    }
    var translating: Bool { ["translating", "queued"].contains(project?.state ?? "") }
    var pendingBatchIDs: [String] { batchIDs.filter { id in !queueItems.contains { $0.project_id == id && ["queued", "running"].contains($0.status) } } }
    var chatModels: [LocalModel] { models.filter { !$0.name.lowercased().contains("plamo") } }
    var visibleUnits: [TextUnit] {
        guard let p = project, let s = p.slides.first(where: { $0.number == slide }) else { return [] }
        let ids = Set(s.units)
        return p.units.filter { ids.contains($0.id) && (notes || $0.kind != "notes") }
    }
    var settingsChanged: Bool {
        guard let p = project else { return false }
        return p.target != target || p.source != source || p.model != translationModel || (p.include_notes ?? false) != notes || p.fit != fit
    }
    var canExport: Bool {
        exportBlockReason == nil
    }
    var progress: Double {
        guard let p = project else { return 0 }
        let units = p.units.filter { (p.include_notes ?? false) || $0.kind != "notes" }
        return Double(units.filter { ["done", "preserved"].contains($0.status) }.count) / Double(max(1, units.count))
    }
    private func service() throws -> NativeEngine { guard let engine else { throw StudioError("アプリを起動できませんでした。表示されたエラーを確認してください。") }; return engine }
    func start() async {
        guard starting, engine == nil else { return }
        do {
            notice = "保存データを確認しています。初回のみ既存データをコピーします。"
            let legacy = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".data")
            let args = CommandLine.arguments
            let override = args.firstIndex(of: "--data-root").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            let service = try await Task.detached(priority: .userInitiated) {
                let root = try override.map { URL(fileURLWithPath: $0) } ?? ProjectStore.defaultRoot()
                if override == nil { try ProjectStore.migrate(legacy: legacy, destination: root) }
                return try NativeEngine(store: ProjectStore(root: root))
            }.value
            engine = service
            await refreshModels()
            projects = await service.projects(); await refreshQueue()
            let requested = args.firstIndex(of: "--open-project").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            if let last = requested ?? UserDefaults.standard.string(forKey: "LastProject"), projects.contains(where: { $0.id == last }) { try await loadProject(last) }
            updatesTask = Task { [weak self] in
                let events = await service.updates()
                for await _ in events {
                    guard !Task.isCancelled, let self else { break }
                    await self.refreshCurrent(); await self.refreshQueue()
                    self.projects = await service.projects()
                    if let error = await service.lastError { self.error = error }
                }
            }
            await service.start()
            if connected { notice = "準備できました。資料も会話もこのMacに保存します。" }
        } catch { self.error = error.localizedDescription; notice = "起動できませんでした。元データは保持されています。" }
        starting = false
    }
    func refreshModels() async {
        do {
            models = try await service().models(); connected = true
            notice = models.isEmpty ? "Ollamaにモデルがありません。INSTALL.mdの手順でモデルを用意してください。" : "モデル一覧を取得しました。実行時に利用できるか再確認します。"
        } catch { connected = false; notice = "Ollamaに接続できません。CLI構成ではTerminalで brew services start ollama を実行し、「接続・モデルを確認」を押してください。既存GUI構成ではOllamaを手動起動してください。" }
    }
    func refreshQueue() async {
        guard let engine else { return }
        let queue = await engine.queueSnapshot(); queueItems = queue.items; queuePaused = queue.paused
        queueError = await engine.lastError
    }
    func selectProject(_ id: String) async throws {
        guard !controlsLocked else { return }
        actionBusy = true; defer { actionBusy = false }
        stopChat(); try await saveDrafts()
        try await loadProject(id)
    }
    private func loadProject(_ id: String) async throws {
        let generation = UUID(); selectionGeneration = generation
        let job = try await service().project(id)
        guard selectionGeneration == generation else { return }
        project = job; slide = 1; source = job.source; target = job.target; translationModel = job.model
        notes = job.include_notes ?? false; fit = job.fit; drafts = [:]
        preview = false; translatedPreview = false; previewImage = nil; previewKey = ""
        bubbles = job.chats.flatMap { [ChatBubble(role: "user", text: $0.question), ChatBubble(role: "assistant", text: $0.answer, refs: $0.refs)] }
        UserDefaults.standard.set(id, forKey: "LastProject")
        await loadPreviewImage()
    }
    func refreshCurrent() async {
        guard let id = project?.id, let engine else { return }
        do {
            let job = try await engine.project(id)
            guard project?.id == id else { return }
            let finished = translating && !["translating", "queued"].contains(job.state)
            if translating || ["translating", "queued"].contains(job.state) {
                // Controls are locked for active requests. Follow their actual
                // options through setup/completion, but preserve genuine edits
                // to idle-project settings on unrelated metadata refreshes.
                source = job.source; target = job.target; translationModel = job.model
                notes = job.include_notes ?? false; fit = job.fit
            }
            project = job
            if finished { notice = job.message }
            await loadPreviewImage()
        } catch { self.error = error.localizedDescription }
    }
    func chooseFile() {
        guard !controlsLocked else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [pptxType]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { let urls = panel.urls; Task { await uploadFiles(urls) } }
    }
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        dropTarget = false
        guard !providers.isEmpty, !controlsLocked else { return false }
        guard providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            notice = "Finderにある.pptxをドロップするか、「PowerPointを開く…」から選んでください。"
            return false
        }
        working = true; actionBusy = true
        error = nil
        notice = "ドロップしたファイルの場所を確認しています…"
        // Initiate every representation request while the drop callback is live.
        // Deadlines run concurrently, so N stalled providers do not cost N×15s.
        let requests = providers.map { FileURLDropLoader.begin($0) }
        Task {
            defer { working = false; actionBusy = false; dropTarget = false }
            var urls: [URL] = []
            var failures: [String] = []
            for request in requests {
                do { urls.append(try await request.value()) }
                catch { failures.append(error.localizedDescription) }
            }
            if !urls.isEmpty { await importFiles(urls, asBatch: providers.count > 1) }
            else { notice = "ファイルを読み込めませんでした。「PowerPointを開く…」から選び直せます。" }
            if !failures.isEmpty {
                let details = failures.joined(separator: "\n")
                error = error.map { $0 + "\n" + details } ?? details
            }
        }
        return true
    }
    func uploadFiles(_ urls: [URL]) async {
        guard !controlsLocked else { notice = "現在の操作が終わるまでお待ちください。"; return }
        working = true; actionBusy = true; defer { working = false; actionBusy = false }
        await importFiles(urls, asBatch: urls.count > 1)
    }
    private func importFiles(_ urls: [URL], asBatch: Bool) async {
        do { try await saveDrafts() } catch { self.error = error.localizedDescription; return }
        var imported: [String] = [], failures: [String] = []
        let settings = (source, target, translationModel, notes, fit)
        for (index, url) in urls.enumerated() {
            notice = "資料を読み込み中 \(index + 1) / \(urls.count): \(url.lastPathComponent)"
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { let job = try await service().importFile(url); imported.append(job.id) }
            catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        do {
            projects = try await service().projects()
            if let first = imported.first { stopChat(); try await loadProject(first) }
            if asBatch { (source, target, translationModel, notes, fit) = settings }
            if asBatch { batchIDs.append(contentsOf: imported) }
            notice = "\(imported.count)件を読み込みました。言語を選んで「この資料を翻訳する」を押してください。" + (asBatch ? " 複数資料は「翻訳の進行状況」からまとめて翻訳できます。" : "")
        } catch { self.error = error.localizedDescription }
        if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
    }
    func saveDrafts() async throws {
        guard let id = project?.id else { return }
        try await saveDrafts(projectID: id, changes: drafts)
    }
    func saveDrafts(projectID id: String, changes: [String: String]) async throws {
        var saved = 0
        for unit in changes.keys.sorted() {
            let translation = changes[unit]!
            do { try await service().edit(id, unit: unit, translation: translation); saved += 1 }
            catch { throw StudioError("\(saved)件の変更をアプリ内に保存しました。残りは未保存です。翻訳・書き出しは実行していません。\n" + error.localizedDescription) }
            if project?.id == id {
                if let index = project?.units.firstIndex(where: { $0.id == unit }) { project?.units[index].translation = translation; project?.units[index].status = "done"; project?.units[index].error = "" }
                if drafts[unit] == translation { drafts.removeValue(forKey: unit) }
            }
        }
    }
    func saveEdits() {
        guard !controlsLocked, let id = project?.id else { return }
        let changes = drafts; actionBusy = true
        Task { defer { actionBusy = false }; do { try await saveDrafts(projectID: id, changes: changes); notice = "訳文の変更をアプリ内に保存しました。PowerPointへの保存は別途必要です。" } catch { self.error = error.localizedDescription } }
    }
    func translate() {
        guard let id = project?.id else { return }
        requestTranslation(ids: [id], options: currentOptions)
    }
    func requestTranslation(ids: [String], options: QueueOptions) {
        guard !controlsLocked, !ids.isEmpty else { return }
        let selectedID = project?.id, changes = drafts
        actionBusy = true; enqueueing = true
        Task {
            do {
                if let selectedID, ids.contains(selectedID) { try await saveDrafts(projectID: selectedID, changes: changes) }
                let assessments = try await service().assessTranslation(ids, options: options)
                let request = TranslationRequest(ids: ids, options: options, assessments: assessments)
                if assessments.contains(where: \.resetsTranslations) { pendingTranslation = request }
                else { await submitTranslation(request, allowReset: false) }
            } catch { self.error = error.localizedDescription; actionBusy = false; enqueueing = false }
        }
    }
    func dismissTranslation(_ request: TranslationRequest) {
        guard pendingTranslation?.id == request.id else { return }
        pendingTranslation = nil; actionBusy = false; enqueueing = false
        notice = "翻訳の予約を中止しました。先にアプリ内へ保存した訳文の変更は保持されています。"
    }
    func confirmTranslation(_ request: TranslationRequest) {
        guard pendingTranslation?.id == request.id else { return }
        pendingTranslation = nil
        Task { await submitTranslation(request, allowReset: true) }
    }
    private func submitTranslation(_ request: TranslationRequest, allowReset: Bool) async {
        defer { actionBusy = false; enqueueing = false }
        do {
            try await service().enqueue(request.ids, options: request.options, assessments: request.assessments, allowReset: allowReset)
            batchIDs.removeAll { request.ids.contains($0) }
            await refreshCurrent(); await refreshQueue()
            notice = "\(request.ids.count)件の翻訳を予約しました。" + (queuePaused ? " 一時停止中です。再開すると順番に翻訳します。" : " 追加順に1件ずつ翻訳します。")
        } catch { self.error = error.localizedDescription }
    }
    func cancelTranslation() { guard let id = project?.id, !actionBusy else { return }; Task { do { try await service().cancelProject(id); await refreshQueue(); await refreshCurrent() } catch { self.error = error.localizedDescription } } }
    func enqueueBatch() {
        requestTranslation(ids: pendingBatchIDs, options: currentOptions)
    }
    func toggleQueuePause() { setQueuePaused(!queuePaused) }
    func setQueuePaused(_ paused: Bool) {
        guard !controlsLocked else { return }; actionBusy = true
        Task { defer { actionBusy = false }; do { try await service().setPaused(paused); await refreshQueue() } catch { self.error = error.localizedDescription } }
    }
    func cancelQueue(_ item: QueueItem) { Task { do { try await service().cancel(item.id); await refreshQueue(); await refreshCurrent() } catch { self.error = error.localizedDescription } } }
    func retryQueue(_ item: QueueItem) { requestTranslation(ids: [item.project_id], options: item.options) }
    func exportCompletedQueue() {
        guard !controlsLocked else { return }
        let items = queueItems.filter { item in item.status == "complete" && queueItems.last(where: { $0.project_id == item.project_id })?.id == item.id }
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "このフォルダへ保存"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let selectedID = project?.id, changes = drafts
        working = true; actionBusy = true
        Task {
            defer { working = false; actionBusy = false }
            do { if let selectedID { try await saveDrafts(projectID: selectedID, changes: changes) } }
            catch { self.error = error.localizedDescription; return }
            var saved = 0, failures: [String] = []
            for item in items {
                do {
                    let job = try await service().project(item.project_id), file = try await service().export(item.project_id)
                    defer { try? FileManager.default.removeItem(at: file) }
                    let stem = (job.filename as NSString).deletingPathExtension + "_" + job.target
                    var destination = directory.appendingPathComponent(stem + ".pptx"), index = 2
                    while FileManager.default.fileExists(atPath: destination.path) { destination = directory.appendingPathComponent(stem + "_\(index).pptx"); index += 1 }
                    let firstDestination = destination
                    try await Task.detached(priority: .userInitiated) {
                        var target = firstDestination, suffix = index
                        while true {
                            do { try atomicSave(file, to: target, overwrite: false); break }
                            catch let error as CocoaError where error.code == .fileWriteFileExists {
                                target = directory.appendingPathComponent(stem + "_\(suffix).pptx"); suffix += 1
                            }
                        }
                    }.value
                    saved += 1
                } catch { failures.append(item.filename + ": " + error.localizedDescription) }
            }
            notice = "\(saved)件のPPTXを保存しました。"
            if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
        }
    }
    func exportPPTX() {
        guard canExport, let p = project else { return }
        let changes = drafts
        working = true; actionBusy = true
        Task {
            defer { working = false; actionBusy = false }
            do {
                try await saveDrafts(projectID: p.id, changes: changes); let file = try await service().export(p.id)
                defer { try? FileManager.default.removeItem(at: file) }
                let panel = NSSavePanel(); panel.allowedContentTypes = [pptxType]; panel.canCreateDirectories = true
                panel.nameFieldStringValue = (p.filename as NSString).deletingPathExtension + "_" + p.target + ".pptx"
                panel.message = "保存先に元の資料や既存のPowerPointを選ぶと、そのファイルを上書きします。"
                if panel.runModal() == .OK, let url = panel.url { try await Task.detached(priority: .userInitiated) { try atomicSave(file, to: url) }.value; notice = "PowerPointを保存しました: " + url.lastPathComponent }
                else { notice = "PowerPointファイルの保存を中止しました。訳文のアプリ内保存は保持されています。" }
            } catch { self.error = error.localizedDescription }
        }
    }
    func renderPreview() {
        guard !controlsLocked, !translatedPreview || canExport, let id = project?.id else { return }
        let translated = translatedPreview, changes = drafts; actionBusy = true
        Task { defer { actionBusy = false }; do { try await saveDrafts(projectID: id, changes: changes); try await service().preview(id, translated: translated); await refreshCurrent() } catch { self.error = error.localizedDescription } }
    }
    func loadPreviewImage() async {
        guard preview, let p = project, p.preview_state != "rendering", let engine else { return }
        let translated = translatedPreview, selectedSlide = slide
        let record = translated ? p.translated_preview : p.source_preview
        let key = "\(p.id)-\(selectedSlide)-\(translated)-\(record?.stamp ?? p.preview_stamp ?? 0)"
        guard previewKey != key else { return }; previewKey = key; previewImage = nil
        do {
            let url = try await engine.previewImage(p.id, translated: translated, slide: selectedSlide)
            let image = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
            if previewKey == key, project?.id == p.id, slide == selectedSlide, translatedPreview == translated, preview { previewImage = image }
        } catch { /* The panel explains how to create a preview. */ }
    }
    func sendChat() {
        guard let id = project?.id, chatBlockReason == nil else { return }
        let question = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chatting, !chatModel.isEmpty else { return }
        let changes = drafts, conversationGeneration = project?.chat_generation ?? ""
        chatInput = ""; chatting = true; actionBusy = true
        let generation = UUID(); chatGeneration = generation
        let model = chatModel, useDocument = useDocument, selectedSlide = currentSlideOnly ? slide : nil
        bubbles.append(ChatBubble(role: "user", text: question)); let bubble = ChatBubble(role: "assistant", text: ""); bubbles.append(bubble)
        chatTask = Task {
            var preparing = true, finalizing = false
            defer { if preparing || finalizing { actionBusy = false }; if chatGeneration == generation { chatting = false; chatFinalizing = false } }
            do {
                try await saveDrafts(projectID: id, changes: changes)
                let (stream, refs) = try await service().chat(id, model: model, question: question, useDocument: useDocument, slide: selectedSlide)
                try Task.checkCancellation()
                guard chatGeneration == generation, project?.id == id else { throw CancellationError() }
                preparing = false; actionBusy = false
                var answer = "", complete = false
                for try await delta in stream {
                    try Task.checkCancellation()
                    guard chatGeneration == generation, project?.id == id, let index = bubbles.firstIndex(where: { $0.id == bubble.id }) else { throw CancellationError() }
                    answer += delta.text; bubbles[index].text = answer; bubbles[index].refs = refs
                    if delta.truncated { notice = "回答が上限に達しました。続けて質問できます。" }
                    if delta.done { complete = true }
                }
                try Task.checkCancellation()
                guard chatGeneration == generation, project?.id == id else { throw CancellationError() }
                if complete {
                    // No MainActor suspension between the final generation check
                    // and locking finalization. A finished answer is now saving,
                    // not an in-progress response that can promise cancellation.
                    finalizing = true; chatFinalizing = true; actionBusy = true
                    try await service().recordChat(id, question: question, answer: answer, refs: refs, model: model, expectedGeneration: conversationGeneration)
                    if chatGeneration == generation, project?.id == id { await refreshCurrent() }
                } else { throw StudioError("回答が途中で終わりました。この質問と回答は履歴に保存されません。") }
            } catch {
                if chatGeneration == generation, let index = bubbles.firstIndex(where: { $0.id == bubble.id }) { bubbles[index].text += "\n" + (Task.isCancelled ? "回答を停止しました。" : error.localizedDescription); bubbles[index].failed = true }
            }
        }
    }
    func stopChat() {
        guard !chatFinalizing else { notice = "回答は完了し、履歴に保存中です。保存が終わるまでお待ちください。"; return }
        if chatting, let index = bubbles.lastIndex(where: { $0.role == "assistant" }) { bubbles[index].text += "\n回答を停止しました。この質問と未完了の回答は履歴に保存されません。"; bubbles[index].failed = true }
        chatTask?.cancel(); chatTask = nil; chatGeneration = UUID(); chatting = false
    }
    func clearChat() {
        guard let p = project, !controlsLocked else { return }
        actionBusy = true
        pendingChatDeletion = ChatDeletionRequest(projectID: p.id, filename: p.filename, generation: p.chat_generation ?? "")
    }
    func dismissChatDeletion(_ request: ChatDeletionRequest) {
        guard pendingChatDeletion?.id == request.id else { return }
        pendingChatDeletion = nil; actionBusy = false
    }
    func confirmChatDeletion(_ request: ChatDeletionRequest) {
        guard pendingChatDeletion?.id == request.id else { return }
        pendingChatDeletion = nil; stopChat()
        Task {
            defer { actionBusy = false }
            do {
                try await service().clearChat(request.projectID, expectedGeneration: request.generation)
                if project?.id == request.projectID { bubbles = []; await refreshCurrent() }
                notice = "この資料の会話履歴を削除しました。資料と訳文は変更していません。"
            } catch { self.error = error.localizedDescription }
        }
    }
    func prepareToQuit() async -> Bool {
        guard !actionBusy else { error = "現在の保存・確認・予約操作を完了するか、キャンセルしてから終了してください。"; return false }
        do { try await saveDrafts(); stopChat(); await engine?.shutdown(); updatesTask?.cancel(); return true }
        catch { self.error = "終了前に保存できませんでした: " + error.localizedDescription; return false }
    }
}

struct Card<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content.padding(20).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.07))) }
}

struct StudioView: View {
    @EnvironmentObject var studio: StudioModel
    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 205, idealWidth: 235, maxWidth: 280)
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text("PowerPointの翻訳・確認・保存").font(.title3.weight(.semibold)); Text("本文はこのMacのローカルAIで処理します").font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    if studio.project != nil { Button { studio.showChat.toggle() } label: { Label(studio.showChat ? "質問欄を閉じる" : "資料について質問", systemImage: "bubble.left.and.bubble.right") }.help("質問欄の表示を切り替えます") }
                }.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 23)
                Divider()
                if studio.starting { Spacer(); ProgressView("ローカルエンジンを起動しています…"); Spacer() }
                else if studio.project == nil { welcome }
                else { workspace }
                HStack { if studio.working || studio.actionBusy { ProgressView().controlSize(.small) }; Text(studio.notice.isEmpty ? "資料を開き、言語を選んで翻訳を始めてください。" : studio.notice).font(.callout).foregroundStyle(.secondary).lineLimit(3); Spacer() }.padding(.horizontal, 25).padding(.vertical, 10)
            }.frame(minWidth: 750).background(canvas)
        }
        .tint(accent)
        .onChange(of: studio.slide) { Task { await studio.loadPreviewImage() } }
        .onChange(of: studio.preview) { Task { await studio.loadPreviewImage() } }
        .onChange(of: studio.translatedPreview) { Task { await studio.loadPreviewImage() } }
        .onDrop(of: [.fileURL], isTargeted: $studio.dropTarget) { providers in
            studio.handleDrop(providers)
        }
        .overlay { if studio.dropTarget { RoundedRectangle(cornerRadius: 10).stroke(accent, lineWidth: 4).padding(6).allowsHitTesting(false) } }
        .alert("Slide Local", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) { Button("OK") { studio.error = nil } } message: { Text(studio.error ?? "") }
        .sheet(isPresented: $studio.showProgress) { TranslationProgressSheet().environmentObject(studio) }
        .sheet(item: Binding(get: { studio.showProgress ? nil : studio.pendingTranslation }, set: { value in if value == nil, !studio.showProgress, let request = studio.pendingTranslation { studio.dismissTranslation(request) } })) { request in
            TranslationConfirmationSheet(request: request).environmentObject(studio)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 0) { Image(systemName: "rectangle.stack.badge.sparkles.fill").font(.title).foregroundStyle(accent).padding(.trailing, 8); Text("slide").font(.title2.bold()); Text("local").font(.title2.weight(.light)) }.padding(.top, 28)
            Button(action: studio.chooseFile) { Label("PowerPointを開く…", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(8) }.buttonStyle(.borderedProminent).disabled(studio.controlsLocked).keyboardShortcut("o")
            HStack { Text("資料一覧").font(.callout).foregroundStyle(.secondary); Spacer(); Text("\(studio.projects.count)件").font(.callout).foregroundStyle(.secondary) }
            ScrollView { LazyVStack(spacing: 6) {
                ForEach(studio.projects) { project in Button { Task { do { try await studio.selectProject(project.id) } catch { studio.error = error.localizedDescription } } } label: {
                    HStack(alignment: .top, spacing: 9) { Image(systemName: "doc.richtext").foregroundStyle(accent.opacity(0.7)); VStack(alignment: .leading, spacing: 4) { Text(project.filename).font(.callout).lineLimit(2).multilineTextAlignment(.leading); Text("\(project.slide_count)スライド · \(project.id.prefix(6))").font(.caption).foregroundStyle(.secondary) }; Spacer(minLength: 0) }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(studio.project?.id == project.id ? accent.opacity(0.1) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(studio.controlsLocked).help(project.filename).accessibilityAddTraits(studio.project?.id == project.id ? .isSelected : []) }
                if studio.projects.isEmpty { Text("追加した資料がここに並びます").font(.caption).foregroundStyle(.tertiary).padding(.top, 8) }
            } }
            Button { studio.showProgress = true } label: { Label("翻訳の進行状況", systemImage: "list.number") }.disabled(studio.starting)
            Spacer(minLength: 0); Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("このMacで翻訳・質問", systemImage: "internaldrive").font(.callout.weight(.medium))
                Text("本文はローカルのOllamaで処理。バックアップ・同期はMacの設定に従います。").font(.caption).foregroundStyle(.secondary)
                Label(studio.connected ? "Ollamaの一覧を取得済み" : "Ollamaに接続できません", systemImage: studio.connected ? "checkmark.circle" : "exclamationmark.circle").font(.caption).foregroundStyle(studio.connected ? accent : .orange)
                Button("接続・モデルを確認") { Task { await studio.refreshModels() } }.font(.callout).buttonStyle(.link).disabled(studio.controlsLocked)
                Link("導入・接続の手順", destination: URL(string: "https://github.com/nyasukun/slide-local/blob/main/INSTALL.md")!).font(.caption)
            }
        }.padding(.horizontal, 18).padding(.bottom, 20).background(.background)
    }
    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            Text("POWERPOINT × LOCAL AI").font(.system(size: 11, weight: .medium)).tracking(2).foregroundStyle(accent)
            VStack(spacing: 5) { Text("言葉の壁を越えて、"); Text("スライドを次の一歩へ。").foregroundStyle(accent) }.font(.system(size: 36, weight: .semibold))
            Text("PowerPointを開く → 翻訳する → 確認・修正 → 保存。\n読み込み・翻訳では元ファイルを変更しません。").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(7)
            Button(action: studio.chooseFile) { VStack(spacing: 12) { Image(systemName: "doc.badge.arrow.up").font(.system(size: 39, weight: .light)).foregroundStyle(accent); Text("PowerPointをここにドロップ").font(.headline); Text("またはクリックしてファイルを選択（複数可）").foregroundStyle(.secondary); Text(".pptx対応 · 空き容量やメモリによる制約があります").font(.callout).foregroundStyle(.secondary) }.frame(maxWidth: 650).padding(.vertical, 36).background(accent.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(accent.opacity(0.35), style: StrokeStyle(lineWidth: 1.3, dash: [6, 4]))) }.buttonStyle(.plain).padding(.horizontal, 45).disabled(studio.controlsLocked)
            HStack(alignment: .top, spacing: 35) { feature("01", "レイアウトを引き継ぐ", "図形や画像を保持してPPTXに保存。"); feature("02", "その場で翻訳を整える", "原文と並べて確認。翻訳文を直接編集。"); feature("03", "資料について質問する", "インストール済みモデルと対話。") }.padding(.top, 15)
            Spacer(minLength: 30)
        }.frame(maxWidth: .infinity)
    }
    private func feature(_ number: String, _ title: String, _ description: String) -> some View { VStack(alignment: .leading, spacing: 8) { HStack { Text(number).font(.system(size: 13, design: .serif)).foregroundStyle(accent.opacity(0.6)); Text(title).font(.system(size: 12, weight: .medium)) }; Text(description).font(.system(size: 10)).foregroundStyle(.secondary) } }
    private var workspace: some View {
        VStack(spacing: 15) {
            HStack { Image(systemName: "doc.richtext.fill").font(.title).foregroundStyle(.orange); VStack(alignment: .leading, spacing: 4) { Text(studio.project?.filename ?? "").font(.headline).lineLimit(2).textSelection(.enabled); Text("\(studio.project?.slide_count ?? 0)スライド · 読み込み・翻訳では元ファイルを変更しません").font(.callout).foregroundStyle(.secondary) }; Spacer() }.padding(.horizontal, 25).padding(.top, 18)
            WorkflowHeader().padding(.horizontal, 25)
            HSplitView {
                ScrollView { VStack(spacing: 16) { TranslationActionCard(); SlideEditor() }.padding(.trailing, 8).padding(.bottom, 12) }.frame(minWidth: 420, idealWidth: 650)
                if studio.showChat { NativeChat().padding(.leading, 10).frame(minWidth: 290, idealWidth: 340) }
            }.padding(.horizontal, 25)
        }
    }
}

let languages: [(String, String)] = [("ja", "日本語"), ("en", "英語"), ("zh-hans", "中国語（簡体）"), ("zh-hant", "中国語（繁体）"), ("ko", "韓国語"), ("fr", "フランス語"), ("de", "ドイツ語"), ("es", "スペイン語")]

struct SlideEditor: View {
    @EnvironmentObject var studio: StudioModel
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("原文と訳文を確認・修正", systemImage: "rectangle.and.pencil.and.ellipsis").font(.headline)
                    Picker("確認する内容", selection: $studio.preview) { Text("文章を比較・編集").tag(false); Text("スライド画像を確認").tag(true) }.pickerStyle(.segmented)
                }
                HStack {
                    Button { studio.slide -= 1 } label: { Image(systemName: "chevron.left") }.disabled(studio.slide <= 1).help("前のスライド").accessibilityLabel("前のスライド")
                    Picker("表示するスライド", selection: $studio.slide) { ForEach(studio.project?.slides ?? []) { Text("スライド \($0.number) / \(studio.project?.slide_count ?? 0)").tag($0.number) } }.labelsHidden().frame(width: 165)
                    Button { studio.slide += 1 } label: { Image(systemName: "chevron.right") }.disabled(studio.slide >= (studio.project?.slide_count ?? 0)).help("次のスライド").accessibilityLabel("次のスライド")
                    Spacer()
                }.disabled(studio.controlsLocked)
                if !studio.drafts.isEmpty { Button("訳文の変更をアプリ内に保存", action: studio.saveEdits).buttonStyle(.borderedProminent).disabled(studio.controlsLocked) }
                if studio.translating { Text("順番待ち・翻訳中は訳文を編集できません。予約を取り消すか、翻訳の完了をお待ちください。").font(.callout).foregroundStyle(.secondary) }
                Divider()
                if studio.preview { previewPanel }
                else {
                    ForEach(studio.visibleUnits) { unit in NativeTextPair(unit: unit) }
                    if studio.visibleUnits.isEmpty { Text("このスライドに編集可能なテキストはありません。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30) }
                }
                Label("画像内の文字・数式・スライドマスターは原文のままです。文字ごとの太字・色などの強調位置は、原文と完全には一致しない場合があります。", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("訳文の変更は、資料の切り替え時とPowerPoint保存時にもアプリ内に保存します。書き出したPowerPointは、保存し直すまで更新されません。").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private var previewPanel: some View {
        VStack(spacing: 12) {
            Picker("プレビューする資料", selection: $studio.translatedPreview) { Text("原本の画像").tag(false); Text("翻訳後の画像").tag(true) }.pickerStyle(.segmented).disabled(studio.controlsLocked)
            HStack { Button("プレビューを作成・更新", action: studio.renderPreview).disabled(studio.controlsLocked || studio.project?.preview_state == "rendering" || (studio.translatedPreview && !studio.canExport)); Spacer() }
            Text(studio.previewFreshness).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if studio.translatedPreview, let reason = studio.exportBlockReason { Text(reason).font(.callout).foregroundStyle(.secondary) }
            if studio.project?.preview_state == "rendering" { ProgressView("スライドを描画しています…").frame(height: 260) }
            else if let image = studio.previewImage { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { VStack(spacing: 12) { Image(systemName: "rectangle.on.rectangle").font(.largeTitle); Text("上の作成・更新ボタンでスライド画像を表示します。") }.font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200).background(canvas) }
            Text("画像の作成にはLibreOfficeが必要です。PowerPointと表示が異なる場合があります。画像が作れなくても文章の確認・翻訳・PowerPoint保存は使えます。").font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct NativeTextPair: View {
    @EnvironmentObject var studio: StudioModel
    let unit: TextUnit
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("原文").font(.callout.weight(.medium)); Spacer(); Text(unit.kind == "notes" ? "発表者ノート" : unit.kind.contains("chart") ? "グラフの文章" : "スライドの文章").font(.callout) }.foregroundStyle(.secondary)
            Text(unit.source).font(.body).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Text("訳文（編集できます）").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { studio.drafts[unit.id] ?? unit.translation }, set: { studio.drafts[unit.id] = $0 })).font(.system(size: 13)).scrollContentBackground(.hidden).padding(7).frame(minHeight: 55, idealHeight: CGFloat(max(55, min(190, (unit.translation.count / 45 + 1) * 23 + 25))))
                .background(accent.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 7)).disabled(studio.translating || studio.controlsLocked).accessibilityLabel("訳文を編集")
            Text(studio.drafts[unit.id] != nil ? "アプリ内に未保存の変更があります" : unit.status == "error" ? "翻訳エラー：" + unit.error : unit.status == "preserved" ? "翻訳せず原文を保持しています" : unit.status == "done" ? "アプリ内に保存済み · PowerPointへの保存は別操作です" : "未翻訳です。自動翻訳するか、ここに訳文を入力できます。")
                .font(.callout).foregroundStyle(unit.status == "error" ? Color.orange : .secondary)
            Divider().padding(.top, 8)
        }
    }
}

struct NativeChat: View {
    @EnvironmentObject var studio: StudioModel
    var body: some View {
        VStack(spacing: 0) {
            HStack { Label("この資料について質問", systemImage: "bubble.left.and.bubble.right").font(.headline); Spacer(); Button(action: studio.clearChat) { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(studio.controlsLocked || (studio.bubbles.isEmpty && studio.project?.chats.isEmpty != false)).help("この資料の会話履歴を削除…").accessibilityLabel("この資料の会話履歴を削除") }.padding(16)
            Divider()
            DisclosureGroup("質問の設定・参照範囲") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("質問用モデル", selection: $studio.chatModel) {
                        if !studio.chatModels.contains(where: { $0.name == studio.chatModel }) { Text("\(studio.chatModel)（利用不可）").tag(studio.chatModel) }
                        ForEach(studio.chatModels) { Text($0.name).tag($0.name) }
                    }
                    Toggle("資料の文章を参照する", isOn: $studio.useDocument).toggleStyle(.checkbox)
                    Toggle("現在のスライドだけに絞る", isOn: $studio.currentSlideOnly).toggleStyle(.checkbox).disabled(!studio.useDocument)
                    Text(studio.useDocument ? "原文と保存済み訳文から関連するスライドの文章を抜粋します。全ページを漏れなく参照するものではありません。画像内の文字・発表者ノートは参照しません。" : "資料を参照せずに質問します。スライドの絞り込みは使いません。")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }.font(.callout).padding(14).disabled(studio.controlsLocked || studio.chatting)
            Divider()
            ScrollViewReader { proxy in
                ScrollView { LazyVStack(alignment: .leading, spacing: 18) {
                    if studio.bubbles.isEmpty { emptyChat }
                    ForEach(studio.bubbles) { bubble in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(bubble.role == "assistant" ? "ローカルAIの回答" : "あなたの質問").font(.caption).foregroundStyle(.secondary)
                            if bubble.text.isEmpty { ProgressView().controlSize(.small).padding(8) }
                            else { Text(bubble.text).font(.body).lineSpacing(5).foregroundStyle(bubble.failed ? Color.orange : Color.primary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                            if bubble.role == "assistant" && !bubble.refs.isEmpty { Text("参照した文章のあるスライド").font(.caption).foregroundStyle(.secondary); ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(bubble.refs, id: \.self) { number in Button("スライド \(number)を表示") { studio.slide = number }.font(.callout).buttonStyle(.bordered).disabled(studio.controlsLocked) } } } }
                        }.padding(bubble.role == "user" ? 12 : 2).frame(maxWidth: .infinity, alignment: .leading).background(bubble.role == "user" ? accent.opacity(0.075) : .clear).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.leading, bubble.role == "user" ? 20 : 0).id(bubble.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(17) }
                .onChange(of: studio.bubbles.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            VStack(spacing: 6) {
                TextEditor(text: $studio.chatInput).font(.body).scrollContentBackground(.hidden).frame(height: 58).padding(8).background(canvas).clipShape(RoundedRectangle(cornerRadius: 7)).overlay(alignment: .topLeading) { if studio.chatInput.isEmpty { Text("質問を入力…").font(.body).foregroundStyle(.secondary).padding(12).allowsHitTesting(false) } }.disabled(studio.controlsLocked).accessibilityLabel("質問を入力")
                HStack {
                    Text("⌘Returnで送信").font(.caption).foregroundStyle(.secondary); Spacer()
                    Button { studio.chatting ? studio.stopChat() : studio.sendChat() } label: { Label(studio.chatFinalizing ? "回答を保存中" : studio.chatting ? "回答を停止" : "質問を送信", systemImage: studio.chatting ? "stop.fill" : "arrow.up") }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(studio.chatFinalizing || (!studio.chatting && studio.chatBlockReason != nil))
                }
                if let reason = studio.chatBlockReason, !studio.chatInput.isEmpty || !studio.connected || !studio.chatModels.contains(where: { $0.name == studio.chatModel }) { Text(reason).font(.callout).foregroundStyle(.secondary) }
                if !studio.chatInput.isEmpty { Text("\(studio.chatInputCount) / 6000文字単位（絵文字などは複数）").font(.caption).foregroundStyle(.secondary) }
                Text("AIの回答は資料と照合してください。停止・失敗した質問と未完了の回答は履歴に保存されません。").font(.caption).foregroundStyle(.secondary)
            }.padding(14)
        }.background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.07)))
            .alert("この資料の会話履歴を削除しますか？", isPresented: Binding(get: { studio.pendingChatDeletion != nil }, set: { value in if !value, let request = studio.pendingChatDeletion { studio.dismissChatDeletion(request) } }), presenting: studio.pendingChatDeletion) { request in
                Button("キャンセル", role: .cancel) { studio.dismissChatDeletion(request) }
                Button("会話履歴を削除", role: .destructive) { studio.confirmChatDeletion(request) }
            } message: { request in Text("\(request.filename)\n保存済みの会話と、画面内の未完了の会話を削除します。取り消せません。資料と訳文は削除しません。") }
    }
    private var emptyChat: some View {
        VStack(spacing: 15) {
            Image(systemName: "sparkles").font(.system(size: 33, weight: .light)).foregroundStyle(accent).padding(16).background(accent.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 17))
            Text("要点や訳語について質問できます").font(.headline)
            Text("候補を選ぶと入力欄に入ります。\n内容を確認して「質問を送信」を押してください。").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            ForEach(["この資料の要点を3つにまとめて", "このスライドをわかりやすく説明して", "翻訳で注意すべき専門用語は？"], id: \.self) { question in Button { studio.chatInput = question } label: { Text("「\(question)」を入力").font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(8) }.buttonStyle(.bordered).disabled(studio.controlsLocked) }
        }.frame(maxWidth: .infinity).padding(.top, 35)
    }
}

@MainActor final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    weak var studio: StudioModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let studio else { return .terminateNow }
        Task { let saved = await studio.prepareToQuit(); sender.reply(toApplicationShouldTerminate: saved) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }
}
#if !STUDIO_TESTS
@main struct SlideLocalNativeApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @StateObject private var studio = StudioModel()
    var body: some Scene {
        Window("Slide Local — PowerPoint翻訳", id: "studio") {
            StudioView().environmentObject(studio).preferredColorScheme(.light).frame(minWidth: 1100, minHeight: 760).task { delegate.studio = studio; await studio.start() }
        }.defaultSize(width: 1450, height: 970).windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) { Button("PowerPointを開く…", action: studio.chooseFile).keyboardShortcut("o").disabled(studio.controlsLocked); Button("翻訳したPowerPointを保存…", action: studio.exportPPTX).keyboardShortcut("s").disabled(!studio.canExport) }
        }
    }
}
#endif
