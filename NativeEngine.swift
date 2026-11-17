import Foundation
import AppKit
import PDFKit

typealias PPTXWriter = @Sendable (URL, [TextUnit], Bool, URL) throws -> Void

actor NativeEngine {
    let store: ProjectStore
    let inference: any LocalInference
    private let pptxWriter: PPTXWriter
    private var queue: QueueState
    private var worker: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var jobs: [String: Project] = [:]
    private var recent: [String] = []
    private var catalog: [ProjectItem]
    private var exports = Set<String>()
    private var previews = Set<String>()
    private var previewTasks: [String: Task<Void, Never>] = [:]
    private var renderBusy = false
    private var shuttingDown = false
    private(set) var lastError: String?

    init(store: ProjectStore, inference: any LocalInference = OllamaClient(), pptxWriter: @escaping PPTXWriter = { try PPTX.export(source: $0, units: $1, fit: $2, destination: $3) }) throws {
        self.store = store; self.inference = inference; self.pptxWriter = pptxWriter
        self.catalog = try store.list()
        self.lastError = store.recoveryMessages.isEmpty ? nil : store.recoveryMessages.joined(separator: "\n")
        var queue = try store.loadQueue()
        for i in queue.items.indices where queue.items[i].status == "running" {
            if queue.items[i].cancel_requested == true { queue.items[i].status = "cancelled"; queue.items[i].message = "停止要求を復元しました。"; queue.items[i].finished = Date().timeIntervalSince1970 }
            else { queue.items[i].status = "queued"; queue.items[i].message = "前回の続きから再開します。" }
        }
        self.queue = queue
        try store.saveQueue(queue)
    }
    func updates() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            listeners[id] = continuation; continuation.yield(())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        }
    }
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
    private func changed() { for listener in listeners.values { listener.yield(()) } }
    private func get(_ id: String) throws -> Project {
        if let job = jobs[id] { return job }
        let job = try store.load(id)
        cache(job)
        return job
    }
    private func cache(_ project: Project) {
        let id = project.id
        jobs[id] = project; recent.removeAll { $0 == id }; recent.append(id)
        while recent.count > 3, let old = recent.first(where: { active($0)?.status != "running" && $0 != id }) {
            recent.removeAll { $0 == old }; jobs.removeValue(forKey: old)
        }
    }
    private func commit(_ project: Project) throws {
        try store.save(project); cache(project)
        if let i = queue.items.firstIndex(where: { $0.project_id == project.id && $0.status == "running" && $0.id == project.translation_request_id }) {
            queue.items[i].completed = project.completed; queue.items[i].total = project.total
        }
        if let i = catalog.firstIndex(where: { $0.id == project.id }) { catalog[i].state = project.state }
        else { catalog.insert(ProjectItem(id: project.id, filename: project.filename, slide_count: project.slide_count, state: project.state), at: 0) }
        changed()
    }
    private func active(_ id: String) -> QueueItem? { queue.items.first { $0.project_id == id && ["queued", "running"].contains($0.status) } }
    func projects() -> [ProjectItem] { catalog.map { value in var v = value; if let a = active(v.id) { v.state = a.status == "queued" ? "queued" : "translating" }; return v } }
    func project(_ id: String) throws -> Project {
        var p = try get(id)
        if let item = active(id) {
            let preparing = p.translation_request_id != item.id
            p.state = item.status == "queued" ? "queued" : "translating"
            if item.status == "queued" { p.message = "翻訳の順番を待っています。" }
            else if preparing { p.message = "選んだ設定で翻訳を準備しています。" }
            p.target = item.options.target; p.source = item.options.source; p.model = item.options.model; p.fit = item.options.fit; p.include_notes = item.options.notes
        } else if p.state == "translating" && active(id) == nil { p.state = "interrupted"; p.message = "前回の翻訳は中断されました。未完了部分を翻訳できます。" }
        if p.preview_state == "rendering" && !previews.contains(id) { p.preview_state = "idle" }
        return p
    }
    func queueSnapshot() -> QueueState { queue }
    func start() { kick() }
    private func kick() {
        guard worker == nil, !shuttingDown, !queue.paused, queue.items.contains(where: { $0.status == "queued" }) else { return }
        worker = Task { await run() }
    }
    func models() async throws -> [LocalModel] { try await inference.models() }
    private func validate(_ options: QueueOptions) async throws {
        guard !options.target.isEmpty, [options.source, options.target].allSatisfy({ $0.isEmpty || $0.range(of: "^[a-z]{2,3}(?:-[a-z]+)?$", options: .regularExpression) != nil }) else { throw StudioError("言語コードが正しくありません。") }
        let installed = try await inference.models()
        guard installed.contains(where: { $0.name == options.model }) else { throw StudioError("このMacに保存されたOllamaモデルを選択してください。") }
    }
    func importFile(_ source: URL) async throws -> Project {
        guard source.pathExtension.lowercased() == "pptx" else { throw StudioError("PPTXファイルを選択してください。") }
        let inventory = try await Task.detached(priority: .userInitiated) { try PPTX.inspect(source) }.value
        let id = newID(), folder = try store.folder(id)
        let stage = store.root.appendingPathComponent(".import-" + id, isDirectory: true)
        let job = Project(id: id, filename: source.lastPathComponent, created: Date().timeIntervalSince1970, slide_count: inventory.slide_count, image_count: inventory.image_count, slides: inventory.slides, units: inventory.units)
        do {
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.copyItem(at: source, to: stage.appendingPathComponent("source.pptx"))
                try JSONEncoder().encode(job).write(to: stage.appendingPathComponent("project.json"), options: .atomic)
                try fm.moveItem(at: stage, to: folder)
            }.value
            cache(job); catalog.insert(ProjectItem(id: id, filename: job.filename, slide_count: job.slide_count, state: job.state), at: 0); changed()
            return job
        } catch { try? FileManager.default.removeItem(at: stage); throw error }
    }

    func assessTranslation(_ ids: [String], options: QueueOptions) throws -> [TranslationAssessment] {
        try ids.map { try TranslationPolicy.assess(get($0), options: options) }
    }
    func enqueue(_ ids: [String], options: QueueOptions, assessments: [TranslationAssessment] = [], allowReset: Bool = false) async throws {
        guard !ids.isEmpty else { throw StudioError("資料を選択してください。") }
        try await validate(options)
        guard Set(ids).count == ids.count else { throw StudioError("同じ資料が重複しています。") }
        var additions: [QueueItem] = []
        for id in ids {
            guard active(id) == nil, !exports.contains(id), !previews.contains(id) else { throw StudioError("選択した資料は処理中または待機中です。") }
            let p = try get(id)
            let current = try TranslationPolicy.assess(p, options: options)
            let approved = assessments.first { $0.projectID == id }
            if !assessments.isEmpty {
                guard approved?.fingerprint == current.fingerprint, approved?.options == options else {
                    throw StudioError("確認中に資料または設定が変わりました。内容を確認して、もう一度実行してください。")
                }
            }
            guard !current.resetsTranslations || (allowReset && approved != nil) else {
                throw StudioError("手動修正を含む現在の訳文が消えます。資料と設定を確認してから翻訳し直してください。")
            }
            additions.append(QueueItem(id: newID(), project_id: id, filename: p.filename, status: "queued", message: "順番を待っています。", options: options, created: Date().timeIntervalSince1970, cancel_requested: false, approved_fingerprint: current.fingerprint))
        }
        var next = queue; next.items.append(contentsOf: additions); try store.saveQueue(next); queue = next; changed(); kick()
    }
    func setPaused(_ paused: Bool) throws { var next = queue; next.paused = paused; try store.saveQueue(next); queue = next; lastError = nil; changed(); kick() }
    func cancel(_ itemID: String) throws {
        guard let index = queue.items.firstIndex(where: { $0.id == itemID }) else { throw StudioError("キューの項目が見つかりません。") }
        var next = queue
        if next.items[index].status == "queued" { next.items[index].status = "cancelled"; next.items[index].message = "待機を取り消しました。"; next.items[index].finished = Date().timeIntervalSince1970 }
        else if next.items[index].status == "running" { next.items[index].cancel_requested = true; next.items[index].message = "現在の段落が終わり次第、停止します。" }
        try store.saveQueue(next); queue = next; changed()
    }
    func cancelProject(_ id: String) throws { if let a = active(id) { try cancel(a.id) } }
    func edit(_ id: String, unit: String, translation: String) throws {
        guard active(id) == nil, !exports.contains(id), !previews.contains(id) else { throw StudioError("処理完了後、またはキュー取消後に編集できます。") }
        guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError("翻訳文を入力してください。") }
        var p = try get(id)
        guard let i = p.units.firstIndex(where: { $0.id == unit }) else { throw StudioError("段落が見つかりません。") }
        p.units[i].translation = translation; p.units[i].status = "done"; p.units[i].error = ""
        p.preview_state = "idle"; p.preview_stamp = Date().timeIntervalSince1970; p.translation_request_id = nil
        p.translated_preview?.state = "stale"
        let selected = p.units.filter { p.include_notes == true || $0.kind != "notes" }
        p.completed = selected.filter { ["done", "preserved"].contains($0.status) }.count
        if p.completed == selected.count { p.state = "complete" }
        try commit(p)
    }
    private func cancelled(_ id: String) -> Bool { shuttingDown || queue.items.first(where: { $0.id == id })?.cancel_requested == true }
    private func run() async {
        defer { worker = nil }
        while !shuttingDown && !queue.paused, let index = queue.items.firstIndex(where: { $0.status == "queued" }) {
            var next = queue
            next.items[index].status = "running"; next.items[index].started = Date().timeIntervalSince1970
            next.items[index].message = "翻訳を準備しています。"
            do { try store.saveQueue(next); queue = next }
            catch { lastError = "翻訳の予約状態を保存できませんでした。保存先を確認し、進行状況から再開してください。\n" + error.localizedDescription; changed(); return }
            let item = queue.items[index]
            changed()
            do {
                let (status, message) = try await translate(item)
                if shuttingDown { return }
                queue.items[index].status = status; queue.items[index].message = message
            } catch {
                if shuttingDown { return }
                queue.items[index].status = "error"; queue.items[index].message = error.localizedDescription
                if var p = try? get(item.project_id) { p.state = "error"; p.message = error.localizedDescription; do { try commit(p) } catch { lastError = error.localizedDescription } }
            }
            queue.items[index].finished = Date().timeIntervalSince1970
            do { try store.saveQueue(queue) } catch { lastError = error.localizedDescription; changed(); return }
            changed()
        }
    }
    private func translate(_ item: QueueItem) async throws -> (String, String) {
        let options = item.options
        let installed: [LocalModel]
        do { installed = try await inference.models() }
        catch {
            if cancelled(item.id) { return try stopPreparation(item) }
            throw error
        }
        var p = try get(item.project_id)
        // Actor reentrancy permits cancellation during model lookup. No settings
        // or translations may be changed before checking the persisted request.
        if cancelled(item.id) {
            p.state = shuttingDown ? "interrupted" : "cancelled"
            p.message = "翻訳の準備中に停止しました。既存の訳文は変更していません。"
            try commit(p)
            return (p.state, p.message)
        }
        guard let installedModel = installed.first(where: { $0.name == options.model }) else { throw StudioError("選択したローカルモデルが見つかりません。") }
        let digest = installedModel.digest ?? options.model
        let current = try TranslationPolicy.assess(p, options: options)
        let alreadyStarted = p.translation_request_id == item.id && TranslationPolicy.options(p) == options
        if !alreadyStarted && ((item.approved_fingerprint != nil && item.approved_fingerprint != current.fingerprint) ||
                              (current.resetsTranslations && item.approved_fingerprint == nil)) {
            p.state = "confirmation"; p.message = "訳文を消す前に確認が必要です。設定と内容を確認して、翻訳を予約し直してください。"
            try commit(p)
            return ("confirmation", p.message)
        }
        if (p.target, p.source, p.model) != (options.target, options.source, options.model) {
            for i in p.units.indices { p.units[i].translation = ""; p.units[i].status = "pending"; p.units[i].error = "" }
        }
        p.state = "translating"; p.target = options.target; p.source = options.source; p.model = options.model; p.fit = options.fit; p.include_notes = options.notes
        p.translation_request_id = item.id
        p.preview_state = "idle"
        p.translated_preview?.state = "stale"
        let selected = p.units.indices.filter { options.notes || p.units[$0].kind != "notes" }
        p.total = selected.count; p.completed = selected.filter { ["done", "preserved"].contains(p.units[$0].status) }.count
        try commit(p)
        for index in selected {
            if cancelled(item.id) { break }
            if ["done", "preserved"].contains(p.units[index].status) { continue }
            let unit = p.units[index]
            p.message = "スライド \(unit.slides.first ?? 1) を翻訳中…"; try commit(p)
            do {
                var value: String, status: String
                if PPTX.shouldPreserve(unit.source) { value = unit.source; status = "preserved" }
                else {
                    let neighbors = selected.map { p.units[$0] }.filter { $0.slides.first == unit.slides.first && $0.id != unit.id }.map { $0.source }.joined(separator: "\n")
                    let context = String(String.UnicodeScalarView(neighbors.unicodeScalars.prefix(350)))
                    let key = try ProjectStore.cacheKey(digest: digest, target: options.target, source: options.source, context: context, text: unit.source)
                    if let cached = try store.cacheGet(key) { value = cached }
                    else {
                        var parts: [String] = []
                        for chunk in OllamaClient.splitText(unit.source) {
                            if cancelled(item.id) { throw CancellationError() }
                            parts.append(try await inference.translate(chunk, target: options.target, model: options.model, source: options.source, context: context))
                        }
                        value = parts.joined(separator: ["en", "fr", "de", "es", "it", "pt"].contains(options.target) ? " " : "")
                        try store.cachePut(key, value: value)
                    }
                    status = "done"
                }
                p.units[index].translation = value; p.units[index].status = status; p.units[index].error = ""
            } catch is CancellationError { break }
            catch { p.units[index].status = "error"; p.units[index].error = error.localizedDescription }
            // Chat may finish while a model call yields; retain the latest persisted conversation.
            mergeLiveMetadata(&p)
            p.completed = selected.filter { ["done", "preserved"].contains(p.units[$0].status) }.count
            try commit(p)
        }
        mergeLiveMetadata(&p)
        if cancelled(item.id) { p.state = shuttingDown ? "interrupted" : "cancelled"; p.message = shuttingDown ? "次回の起動時に続きから再開します。" : "翻訳を停止しました。完了した部分は保存されています。" }
        else {
            let failures = selected.filter { p.units[$0].status == "error" }.count
            p.state = failures > 0 ? "review" : "complete"
            p.message = failures > 0 ? "\(failures)か所で翻訳に失敗しました。修正または未完了部分の翻訳を実行できます。" : "翻訳が完了しました。内容を確認し、PowerPointの保存先を選んでください。"
        }
        if p.state == "complete" { _ = try await build(p) }
        if cancelled(item.id) {
            p.state = shuttingDown ? "interrupted" : "cancelled"
            p.message = shuttingDown ? "PowerPoint作成中に終了しました。次回、未完了処理を復元します。" : "翻訳の停止を反映しました。完了した訳文は保持しています。全て翻訳済みならPowerPointを保存できます。"
        }
        mergeLiveMetadata(&p)
        try commit(p)
        return (p.state, p.message)
    }
    private func stopPreparation(_ item: QueueItem) throws -> (String, String) {
        var p = try get(item.project_id)
        p.state = shuttingDown ? "interrupted" : "cancelled"
        p.message = "翻訳の準備中に停止しました。既存の訳文は変更していません。"
        try commit(p)
        return (p.state, p.message)
    }
    private func mergeLiveMetadata(_ project: inout Project) {
        guard let live = jobs[project.id] else { return }
        project.chats = live.chats
        project.chat_generation = live.chat_generation
        project.preview_state = live.preview_state; project.preview_version = live.preview_version
        project.preview_error = live.preview_error; project.preview_stamp = live.preview_stamp
        project.source_preview = live.source_preview; project.translated_preview = live.translated_preview
    }
    private func build(_ p: Project, unique: Bool = false) async throws -> URL {
        let units = p.units.filter { p.include_notes == true || $0.kind != "notes" }
        guard units.allSatisfy({ ["done", "preserved"].contains($0.status) }) else { throw StudioError("未翻訳の箇所があります。翻訳を実行するか、翻訳文を修正してください。") }
        guard !exports.contains(p.id) else { throw StudioError("PPTXを作成中です。") }
        exports.insert(p.id); defer { exports.remove(p.id) }
        let folder = try store.folder(p.id), output = folder.appendingPathComponent(unique ? "export-" + newID() + ".pptx" : "translated.pptx"), temporary = folder.appendingPathComponent("translated-" + newID() + ".tmp")
        let writer = pptxWriter
        try await Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: temporary) }
            try writer(folder.appendingPathComponent("source.pptx"), units, p.fit, temporary)
            if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: output) }
        }.value
        return output
    }
    func export(_ id: String) async throws -> URL {
        guard active(id) == nil else { throw StudioError("キューの処理完了後に保存できます。") }
        return try await build(get(id), unique: true)
    }
    func chat(_ id: String, model: String, question: String, useDocument: Bool, slide: Int?) async throws -> (AsyncThrowingStream<ChatDelta, Error>, [Int]) {
        guard !model.lowercased().contains("plamo"), !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.unicodeScalars.count <= 6000 else { throw StudioError("会話モデルと6000文字以内の質問を入力してください。") }
        let available = try await inference.models()
        guard available.contains(where: { $0.name == model }) else { throw StudioError("このMacの会話モデルを選択してください。") }
        let (messages, refs) = try DocumentReference.messages(try get(id), question: question, useDocument: useDocument, slide: slide)
        return (inference.chat(model: model, messages: messages), refs)
    }
    func recordChat(_ id: String, question: String, answer: String, refs: [Int], model: String, expectedGeneration: String? = nil) throws {
        try Task.checkCancellation()
        var p = try get(id)
        if let expectedGeneration, (p.chat_generation ?? "") != expectedGeneration { throw StudioError("会話履歴が変わったため、遅れて届いた回答は保存しませんでした。") }
        p.chats.append(ChatRecord(question: question, answer: answer, refs: refs, model: model)); p.chat_generation = newID(); try commit(p)
    }
    func clearChat(_ id: String, expectedGeneration: String? = nil) throws {
        var p = try get(id)
        if let expectedGeneration, (p.chat_generation ?? "") != expectedGeneration { throw StudioError("確認中に会話が更新されました。内容を確認して、削除をやり直してください。") }
        p.chats = []; p.chat_generation = newID(); try commit(p)
    }
    func preview(_ id: String, translated: Bool) throws {
        guard !previews.contains(id), !renderBusy else { throw StudioError("現在のプレビュー作成が終わるまでお待ちください。") }
        if translated && active(id) != nil { throw StudioError("キューの処理完了後にプレビューできます。") }
        var p = try get(id); p.preview_state = "rendering"; p.preview_error = ""
        let record = PreviewRecord(state: "rendering", fingerprint: try TranslationPolicy.previewFingerprint(p, translated: translated))
        if translated { p.translated_preview = record } else { p.source_preview = record }
        try commit(p)
        previews.insert(id); renderBusy = true
        previewTasks[id] = Task { await self.render(id, translated: translated) }
    }
    private func render(_ id: String, translated: Bool) async {
        defer { previews.remove(id); previewTasks.removeValue(forKey: id); renderBusy = false; changed() }
        do {
            let p = try get(id), folder = try store.folder(id)
            let source = try await translated ? build(p) : folder.appendingPathComponent("source.pptx")
            let version = translated ? "translated" : "source"
            let outdir = folder.appendingPathComponent("preview-" + version)
            try await Task.detached(priority: .utility) { try NativePreview.render(source: source, output: outdir) }.value
            var live = try get(id)
            let fresh = (try TranslationPolicy.previewFingerprint(p, translated: translated)) == (try TranslationPolicy.previewFingerprint(live, translated: translated))
            let record = PreviewRecord(state: fresh ? "ready" : "stale", fingerprint: try TranslationPolicy.previewFingerprint(p, translated: translated), stamp: Date().timeIntervalSince1970)
            if translated { live.translated_preview = record } else { live.source_preview = record }
            live.preview_state = record.state; live.preview_version = version; live.preview_stamp = record.stamp; live.preview_error = ""; try commit(live)
        } catch { do {
            var p = try get(id); p.preview_state = "error"; p.preview_error = error.localizedDescription
            let record = PreviewRecord(state: "error", error: error.localizedDescription)
            if translated { p.translated_preview = record } else { p.source_preview = record }
            try commit(p)
        } catch { lastError = error.localizedDescription } }
    }
    func previewImage(_ id: String, translated: Bool, slide: Int) async throws -> URL {
        let p = try get(id)
        guard (1...max(1, p.slide_count)).contains(slide) else { throw StudioError("スライドが見つかりません。") }
        let folder = try store.folder(id).appendingPathComponent("preview-" + (translated ? "translated" : "source"))
        return try await Task.detached(priority: .utility) { try NativePreview.image(folder: folder, translated: translated, slide: slide) }.value
    }
    func shutdown() { shuttingDown = true; worker?.cancel(); for task in previewTasks.values { task.cancel() }; changed() }
}

struct NativePreview {
    static func render(source: URL, output: URL) throws {
        let fm = FileManager.default
        let candidates = ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"]
        guard let executable = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { throw StudioError("プレビューにはLibreOfficeが必要です。翻訳とPPTX保存はそのまま使えます。") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let scratch = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("slp-" + String(newID().prefix(16)))
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let root = URL(fileURLWithPath: try NativePreviewPolicy.physicalPath(scratch), isDirectory: true)
        for name in ["home", "tmp", "profile/user", "result"] { try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let input = root.appendingPathComponent("input.pptx")
        try PPTX.preparePreview(source: source, destination: input)
        try Data(NativePreviewPolicy.preferences.utf8).write(to: root.appendingPathComponent("profile/user/registrymodifications.xcu"), options: .atomic)
        let policy = root.appendingPathComponent("renderer.sb")
        try Data(NativePreviewPolicy.sandbox.utf8).write(to: policy, options: .atomic)
        let realExecutable = try NativePreviewPolicy.physicalPath(URL(fileURLWithPath: executable))
        guard let range = realExecutable.range(of: ".app/Contents/MacOS/") else { throw StudioError("隔離できるLibreOfficeアプリが見つかりません。") }
        let appPath = String(realExecutable[..<range.lowerBound]) + ".app"
        let userFonts = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts").path
        let log = root.appendingPathComponent("render.log"); fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.environment = NativePreviewPolicy.environment(root: root)
        process.currentDirectoryURL = root
        process.arguments = ["-D", "RENDER_ROOT=" + root.path, "-D", "LO_APP=" + appPath, "-D", "USER_FONTS=" + userFonts, "-f", policy.path,
                             realExecutable, "-env:OSL_SOCKET_PATH=" + root.path, "-env:UserInstallation=" + root.appendingPathComponent("profile").absoluteString,
                             "--headless", "--norestore", "--nodefault", "--nofirststartwizard", "--convert-to", "pdf", "--outdir", root.appendingPathComponent("result").path, input.path]
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); throw StudioError("プレビュー作成がタイムアウトしました。") }
        let generated = root.appendingPathComponent("result/input.pdf")
        guard process.terminationStatus == 0, fm.fileExists(atPath: generated.path) else { throw StudioError("隔離環境でプレビューを作成できませんでした。安全のため通信制限を解除せず停止しました。翻訳とPPTX保存は利用できます。") }
        try NativePreviewPolicy.promotePDF(root: root, destination: output.appendingPathComponent("slides.pdf"))
        // Existing legacy PNGs must not mask a freshly rendered PDF.
        for file in try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("slide-") && file.pathExtension == "png" { try fm.removeItem(at: file) }
    }
    static func image(folder: URL, translated: Bool, slide: Int) throws -> URL {
        let fm = FileManager.default, target = folder.appendingPathComponent("slide-\(slide).png")
        if fm.fileExists(atPath: target.path) { return target }
        var pdf = folder.appendingPathComponent("slides.pdf")
        if !fm.fileExists(atPath: pdf.path) { pdf = folder.appendingPathComponent(translated ? "translated.pdf" : "source.pdf") }
        guard let document = PDFDocument(url: pdf), let page = document.page(at: slide - 1) else { throw StudioError("「プレビューを作成」でスライドを表示します。") }
        let bounds = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: NSSize(width: bounds.width * 1.4, height: bounds.height * 1.4), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { throw StudioError("スライド画像を作成できません。") }
        try data.write(to: target, options: .atomic); return target
    }
}
