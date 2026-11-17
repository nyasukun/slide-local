import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let pptxType = UTType(filenameExtension: "pptx") ?? .data
private let accent = Color(red: 0.13, green: 0.43, blue: 0.33)
private let canvas = Color(red: 0.97, green: 0.98, blue: 0.96)

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
    @Published var dropTarget = false
    @Published var queueItems: [QueueItem] = []
    @Published var queuePaused = false
    @Published var batchIDs: [String] = []
    @Published var enqueueing = false
    private var engine: NativeEngine?
    private var updatesTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var chatGeneration = UUID()
    private var selectionGeneration = UUID()
    private var previewKey = ""
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
        guard let p = project, !translating, !settingsChanged else { return false }
        return p.units.filter { (p.include_notes ?? false) || $0.kind != "notes" }.allSatisfy { ["done", "preserved"].contains($0.status) || drafts[$0.id]?.isEmpty == false }
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
            if let last = requested ?? UserDefaults.standard.string(forKey: "LastProject"), projects.contains(where: { $0.id == last }) { try await selectProject(last) }
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
            if !models.contains(where: { $0.name == translationModel }) { translationModel = models.first(where: { $0.name.contains("plamo") })?.name ?? models.first?.name ?? "" }
            if !chatModels.contains(where: { $0.name == chatModel }) { chatModel = chatModels.first(where: { $0.name.contains("qwen") })?.name ?? chatModels.first?.name ?? "" }
        } catch { connected = false; notice = "Ollama未接続。CLI構成ではTerminalで brew services start ollama を実行し、「モデルを再読み込み」を押してください。既存GUI構成ではOllamaを手動起動してください。" }
    }
    func refreshQueue() async {
        guard let engine else { return }
        let queue = await engine.queueSnapshot(); queueItems = queue.items; queuePaused = queue.paused
    }
    func selectProject(_ id: String) async throws {
        try await saveDrafts(); stopChat()
        let generation = UUID(); selectionGeneration = generation
        let job = try await service().project(id)
        guard selectionGeneration == generation else { return }
        project = job; slide = 1; source = job.source; target = job.target; translationModel = job.model
        notes = job.include_notes ?? false; fit = job.fit; drafts = [:]; previewImage = nil; previewKey = ""
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
            project = job
            if finished { notice = job.message }
            await loadPreviewImage()
        } catch { self.error = error.localizedDescription }
    }
    func chooseFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [pptxType]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { let urls = panel.urls; Task { await uploadFiles(urls) } }
    }
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) } }
                if let url { urls.append(url) }
            }
            if !urls.isEmpty { await uploadFiles(urls) }
        }
        return true
    }
    func uploadFiles(_ urls: [URL]) async {
        guard !working else { notice = "現在の読み込みが終わるまでお待ちください。"; return }
        working = true; defer { working = false }
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
            if let first = imported.first { try await selectProject(first) }
            if urls.count > 1 { (source, target, translationModel, notes, fit) = settings }
            batchIDs.append(contentsOf: imported)
            notice = "\(imported.count)件を読み込みました。設定を選び「まとめてキューに追加」で順番に翻訳します。"
        } catch { self.error = error.localizedDescription }
        if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
    }
    func saveDrafts() async throws {
        guard let id = project?.id else { return }
        let changes = drafts
        for (unit, translation) in changes {
            try await service().edit(id, unit: unit, translation: translation)
            if project?.id == id {
                if let index = project?.units.firstIndex(where: { $0.id == unit }) { project?.units[index].translation = translation; project?.units[index].status = "done"; project?.units[index].error = "" }
                if drafts[unit] == translation { drafts.removeValue(forKey: unit) }
            }
        }
    }
    func saveEdits() { Task { do { try await saveDrafts(); notice = "翻訳文の変更を保存しました。" } catch { self.error = error.localizedDescription } } }
    private func options() -> QueueOptions { QueueOptions(target: target, source: source, model: translationModel, notes: notes, fit: fit) }
    func translate() {
        guard let id = project?.id, !enqueueing else { return }
        enqueueing = true; let settings = options()
        Task { defer { enqueueing = false }; do { try await saveDrafts(); try await service().enqueue([id], options: settings); batchIDs.removeAll { $0 == id }; await refreshCurrent(); await refreshQueue() } catch { self.error = error.localizedDescription } }
    }
    func cancelTranslation() { guard let id = project?.id else { return }; Task { do { try await service().cancelProject(id) } catch { self.error = error.localizedDescription } } }
    func enqueueBatch() {
        let ids = pendingBatchIDs, settings = options()
        guard !ids.isEmpty, !enqueueing else { return }
        enqueueing = true
        Task { defer { enqueueing = false }; do { try await saveDrafts(); try await service().enqueue(ids, options: settings); batchIDs.removeAll { ids.contains($0) }; await refreshQueue(); await refreshCurrent(); notice = "\(ids.count)件をキューへ登録しました。追加順に1件ずつ処理します。" } catch { self.error = error.localizedDescription } }
    }
    func toggleQueuePause() { Task { do { try await service().setPaused(!queuePaused); await refreshQueue() } catch { self.error = error.localizedDescription } } }
    func cancelQueue(_ item: QueueItem) { Task { do { try await service().cancel(item.id); await refreshQueue(); await refreshCurrent() } catch { self.error = error.localizedDescription } } }
    func retryQueue(_ item: QueueItem) { Task { do { try await service().enqueue([item.project_id], options: item.options); await refreshQueue(); await refreshCurrent() } catch { self.error = error.localizedDescription } } }
    func exportCompletedQueue() {
        let items = queueItems.filter { item in item.status == "complete" && queueItems.last(where: { $0.project_id == item.project_id })?.id == item.id }
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "このフォルダへ保存"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        working = true
        Task {
            defer { working = false }
            var saved = 0, failures: [String] = []
            for item in items {
                do {
                    let job = try await service().project(item.project_id), file = try await service().export(item.project_id)
                    let stem = (job.filename as NSString).deletingPathExtension + "_" + job.target
                    var destination = directory.appendingPathComponent(stem + ".pptx"), index = 2
                    while FileManager.default.fileExists(atPath: destination.path) { destination = directory.appendingPathComponent(stem + "_\(index).pptx"); index += 1 }
                    let target = destination
                    try await Task.detached(priority: .userInitiated) { try atomicSave(file, to: target) }.value
                    saved += 1
                } catch { failures.append(item.filename + ": " + error.localizedDescription) }
            }
            notice = "\(saved)件のPPTXを保存しました。"
            if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
        }
    }
    func exportPPTX() {
        guard let p = project else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await saveDrafts(); let file = try await service().export(p.id)
                let panel = NSSavePanel(); panel.allowedContentTypes = [pptxType]; panel.canCreateDirectories = true
                panel.nameFieldStringValue = (p.filename as NSString).deletingPathExtension + "_" + p.target + ".pptx"
                if panel.runModal() == .OK, let url = panel.url { try await Task.detached(priority: .userInitiated) { try atomicSave(file, to: url) }.value; notice = "保存しました: " + url.lastPathComponent }
            } catch { self.error = error.localizedDescription }
        }
    }
    func renderPreview() { guard let id = project?.id else { return }; Task { do { try await saveDrafts(); try await service().preview(id, translated: translatedPreview); await refreshCurrent() } catch { self.error = error.localizedDescription } } }
    func loadPreviewImage() async {
        guard preview, let p = project, p.preview_state != "rendering", let engine else { return }
        let key = "\(p.id)-\(slide)-\(translatedPreview)-\(p.preview_stamp ?? 0)"
        guard previewKey != key else { return }; previewKey = key; previewImage = nil
        do {
            let url = try await engine.previewImage(p.id, translated: translatedPreview, slide: slide)
            let image = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
            if previewKey == key { previewImage = image }
        } catch { /* The panel explains how to create a preview. */ }
    }
    func sendChat() {
        guard let id = project?.id else { return }
        let question = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chatting, !chatModel.isEmpty else { return }
        chatInput = ""; chatting = true
        let generation = UUID(); chatGeneration = generation
        let model = chatModel, useDocument = useDocument, selectedSlide = currentSlideOnly ? slide : nil
        bubbles.append(ChatBubble(role: "user", text: question)); let bubble = ChatBubble(role: "assistant", text: ""); bubbles.append(bubble)
        chatTask = Task {
            defer { if chatGeneration == generation { chatting = false } }
            do {
                try await saveDrafts()
                let (stream, refs) = try await service().chat(id, model: model, question: question, useDocument: useDocument, slide: selectedSlide)
                var answer = "", complete = false
                for try await delta in stream {
                    try Task.checkCancellation()
                    guard chatGeneration == generation, project?.id == id, let index = bubbles.firstIndex(where: { $0.id == bubble.id }) else { throw CancellationError() }
                    answer += delta.text; bubbles[index].text = answer; bubbles[index].refs = refs
                    if delta.truncated { notice = "回答が上限に達しました。続けて質問できます。" }
                    if delta.done { complete = true }
                }
                try Task.checkCancellation()
                if complete { try await service().recordChat(id, question: question, answer: answer, refs: refs, model: model) }
            } catch {
                if chatGeneration == generation, let index = bubbles.firstIndex(where: { $0.id == bubble.id }) { bubbles[index].text += "\n" + (Task.isCancelled ? "回答を停止しました。" : error.localizedDescription); bubbles[index].failed = true }
            }
        }
    }
    func stopChat() {
        if chatting, let index = bubbles.lastIndex(where: { $0.role == "assistant" }) { bubbles[index].text += "\n回答を停止しました。"; bubbles[index].failed = true }
        chatTask?.cancel(); chatTask = nil; chatGeneration = UUID(); chatting = false
    }
    func clearChat() { guard let id = project?.id, !chatting else { return }; Task { do { try await service().clearChat(id); if project?.id == id { bubbles = [] } } catch { self.error = error.localizedDescription } } }
    func prepareToQuit() async -> Bool {
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
                    VStack(alignment: .leading, spacing: 5) { Text("LOCAL INTELLIGENCE").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary); Text("翻訳して、理解を深める。").font(.system(size: 21, weight: .semibold)) }
                    Spacer(); Label("LOCAL ONLY", systemImage: "lock.shield").font(.system(size: 10, weight: .medium)).foregroundStyle(accent).padding(9).background(accent.opacity(0.07)).clipShape(Capsule())
                }.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 23)
                Divider()
                if studio.starting { Spacer(); ProgressView("ローカルエンジンを起動しています…"); Spacer() }
                else if studio.project == nil { welcome }
                else { workspace }
                HStack { if studio.working { ProgressView().controlSize(.small) }; Text(studio.notice.isEmpty ? "Built with PLaMo · Powered by Ollama · このMacの中で完結" : studio.notice).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2); Spacer() }.padding(.horizontal, 25).padding(.vertical, 10)
            }.frame(minWidth: 850).background(canvas)
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
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) { Image(systemName: "rectangle.stack.badge.sparkles.fill").font(.system(size: 29)).foregroundStyle(accent); Text("slide").font(.system(size: 25, weight: .bold)) + Text("local").font(.system(size: 25, weight: .light)) }.padding(.top, 28)
            Button(action: studio.chooseFile) { Label("資料を追加", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(9) }.buttonStyle(.borderedProminent).disabled(studio.working || studio.starting).keyboardShortcut("o")
            HStack { Text("ライブラリ").font(.caption).foregroundStyle(.secondary); Spacer(); Text("\(studio.projects.count)").font(.caption2).foregroundStyle(.secondary) }
            ScrollView { LazyVStack(spacing: 6) {
                ForEach(studio.projects) { project in Button { Task { do { try await studio.selectProject(project.id) } catch { studio.error = error.localizedDescription } } } label: {
                    HStack(alignment: .top, spacing: 9) { Image(systemName: "doc.richtext").foregroundStyle(accent.opacity(0.7)); VStack(alignment: .leading, spacing: 4) { Text(project.filename).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading); Text("\(project.slide_count) slides").font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(minLength: 0) }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(studio.project?.id == project.id ? accent.opacity(0.1) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain) }
                if studio.projects.isEmpty { Text("追加した資料がここに並びます").font(.caption).foregroundStyle(.tertiary).padding(.top, 8) }
            } }
            Spacer(minLength: 0); Divider()
            VStack(alignment: .leading, spacing: 8) { Label("このMacの中で完結", systemImage: "internaldrive").font(.system(size: 12, weight: .medium)); Text("資料も会話もローカルに保存。\nクラウドへは送信しません。").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4); Label(studio.connected ? "Ollama 接続済み" : "Ollama 未接続", systemImage: "circle.fill").font(.system(size: 10)).foregroundStyle(studio.connected ? accent : .orange); Button("モデルを再読み込み") { Task { await studio.refreshModels() } }.font(.caption).buttonStyle(.link) }
        }.padding(.horizontal, 18).padding(.bottom, 20).background(.background)
    }
    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            Text("POWERPOINT × LOCAL AI").font(.system(size: 11, weight: .medium)).tracking(2).foregroundStyle(accent)
            VStack(spacing: 5) { Text("言葉の壁を越えて、"); Text("スライドを次の一歩へ。").foregroundStyle(accent) }.font(.system(size: 36, weight: .semibold))
            Text("PowerPointをそのまま翻訳。気になるところは、AIと対話。\nあなたの資料は、あなたのMacから出ません。").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(7)
            Button(action: studio.chooseFile) { VStack(spacing: 12) { Image(systemName: "doc.badge.arrow.up").font(.system(size: 39, weight: .light)).foregroundStyle(accent); Text("PowerPointをここにドロップ").font(.system(size: 16, weight: .medium)); Text("またはクリックしてファイルを選択").foregroundStyle(.secondary); Text(".pptx · 容量制限なし").font(.caption2).foregroundStyle(.tertiary) }.frame(maxWidth: 650).padding(.vertical, 36).background(accent.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(accent.opacity(0.35), style: StrokeStyle(lineWidth: 1.3, dash: [6, 4]))) }.buttonStyle(.plain).padding(.horizontal, 45).disabled(studio.working)
            HStack(alignment: .top, spacing: 35) { feature("01", "レイアウトを引き継ぐ", "図形や画像を保持してPPTXに保存。"); feature("02", "その場で翻訳を整える", "原文と並べて確認。翻訳文を直接編集。"); feature("03", "資料について質問する", "インストール済みモデルと対話。") }.padding(.top, 15)
            Spacer(minLength: 30)
        }.frame(maxWidth: .infinity)
    }
    private func feature(_ number: String, _ title: String, _ description: String) -> some View { VStack(alignment: .leading, spacing: 8) { HStack { Text(number).font(.system(size: 13, design: .serif)).foregroundStyle(accent.opacity(0.6)); Text(title).font(.system(size: 12, weight: .medium)) }; Text(description).font(.system(size: 10)).foregroundStyle(.secondary) } }
    private var workspace: some View {
        VStack(spacing: 15) {
            HStack { Image(systemName: "doc.richtext.fill").font(.system(size: 28)).foregroundStyle(.orange); VStack(alignment: .leading, spacing: 4) { Text(studio.project?.filename ?? "").font(.system(size: 15, weight: .semibold)).lineLimit(1); Text("\(studio.project?.slide_count ?? 0)スライド · 画像\(studio.project?.image_count ?? 0)点").font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(); Button(action: studio.exportPPTX) { Label("PPTXを保存", systemImage: "square.and.arrow.down") }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!studio.canExport || studio.working).keyboardShortcut("s") }.padding(.horizontal, 25).padding(.top, 18)
            HSplitView {
                ScrollView { VStack(spacing: 16) { TranslationSettings(); NativeQueue(); SlideEditor() }.padding(.trailing, 8).padding(.bottom, 12) }.frame(minWidth: 440, idealWidth: 650)
                NativeChat().padding(.leading, 10).frame(minWidth: 320, idealWidth: 390)
            }.padding(.horizontal, 25)
        }
    }
}

let languages: [(String, String)] = [("ja", "日本語"), ("en", "英語"), ("zh-hans", "中国語（簡体）"), ("zh-hant", "中国語（繁体）"), ("ko", "韓国語"), ("fr", "フランス語"), ("de", "ドイツ語"), ("es", "スペイン語")]

struct TranslationSettings: View {
    @EnvironmentObject var studio: StudioModel
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 17) {
                Label("スライドを翻訳", systemImage: "character.book.closed").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 14) {
                    Picker("原文", selection: $studio.source) { Text("自動判定").tag(""); ForEach(languages, id: \.0) { Text($0.1).tag($0.0) } }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Picker("翻訳先", selection: $studio.target) { ForEach(languages, id: \.0) { Text($0.1).tag($0.0) } }
                }.disabled(studio.translating)
                Picker("翻訳モデル", selection: $studio.translationModel) { ForEach(studio.models) { Text($0.name).tag($0.name) } }.disabled(studio.translating)
                HStack(spacing: 23) { Toggle("ノートも翻訳", isOn: $studio.notes); Toggle("文字を枠に収める", isOn: $studio.fit) }.toggleStyle(.checkbox).font(.system(size: 11)).disabled(studio.translating)
                HStack { Button(action: studio.translate) { Label(studio.translating ? "処理中／待機中" : "この資料をキューに追加", systemImage: "sparkles") }.buttonStyle(.borderedProminent).controlSize(.large).disabled(studio.translating || !studio.connected || studio.translationModel.isEmpty || studio.working)
                    if studio.translating { Button("停止", action: studio.cancelTranslation).buttonStyle(.bordered) }
                    Text(studio.settingsChanged ? "設定変更を翻訳に反映します。" : studio.project?.message ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                }
                if !studio.pendingBatchIDs.isEmpty {
                    HStack { Text("追加した資料 \(studio.pendingBatchIDs.count)件").font(.caption).foregroundStyle(.secondary); Spacer(); Button("まとめてキューに追加", action: studio.enqueueBatch).buttonStyle(.borderedProminent).disabled(!studio.connected || studio.translationModel.isEmpty || studio.working) }
                }
                if studio.progress > 0 || studio.translating { ProgressView(value: studio.progress).tint(accent) }
            }
        }
    }
}

struct NativeQueue: View {
    @EnvironmentObject var studio: StudioModel
    private var waiting: Int { studio.queueItems.filter { $0.status == "queued" }.count }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Label("翻訳キュー", systemImage: "list.number").font(.system(size: 14, weight: .semibold)); Spacer(); Text("待機 \(waiting)件").font(.caption).foregroundStyle(.secondary); Button(studio.queuePaused ? "再開" : "一時停止", action: studio.toggleQueuePause).buttonStyle(.bordered) }
                Text(studio.queuePaused ? "現在の処理が終わったところで待機します。再開すると続きから処理します。" : "追加順に1件ずつ翻訳し、PPTXを作成します。エラーの後も次の資料へ進みます。").font(.system(size: 10)).foregroundStyle(.secondary)
                if studio.queueItems.isEmpty { Text("複数の資料を追加して、上のボタンからキューに登録できます。").font(.caption).foregroundStyle(.tertiary).padding(.vertical, 10) }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(studio.queueItems) { item in
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: item.status == "running" ? "arrow.triangle.2.circlepath" : item.status == "complete" ? "checkmark.circle.fill" : item.status == "queued" ? "clock" : "exclamationmark.circle").foregroundStyle(item.status == "error" || item.status == "review" ? Color.orange : accent)
                                    Button { Task { do { try await studio.selectProject(item.project_id) } catch { studio.error = error.localizedDescription } } } label: {
                                        VStack(alignment: .leading, spacing: 3) { Text(item.filename).font(.system(size: 11, weight: .medium)).lineLimit(1); Text(label(item) + " · " + item.message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                    if ["queued", "running"].contains(item.status) { Button(item.status == "queued" ? "取消" : "停止") { studio.cancelQueue(item) }.font(.caption).buttonStyle(.bordered) }
                                    else if ["error", "review", "cancelled"].contains(item.status) { Button("再登録") { studio.retryQueue(item) }.font(.caption).buttonStyle(.bordered) }
                                }
                            }
                        }.padding(.vertical, 3)
                    }.frame(maxHeight: 190)
                }
                if studio.queueItems.contains(where: { $0.status == "complete" }) { Button("完了したPPTXをフォルダへまとめて保存", action: studio.exportCompletedQueue).font(.caption).buttonStyle(.bordered).disabled(studio.working) }
            }
        }
    }
    private func label(_ item: QueueItem) -> String {
        switch item.status { case "queued": return "待機中"; case "running": return "処理中 \(item.completed ?? 0)/\(item.total ?? 0)"; case "complete": return "完了"; case "review": return "要確認"; case "cancelled": return "取消済み"; default: return "エラー" }
    }
}

struct SlideEditor: View {
    @EnvironmentObject var studio: StudioModel
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 15) {
                HStack { Label("確認・編集", systemImage: "rectangle.and.pencil.and.ellipsis").font(.system(size: 14, weight: .semibold)); Spacer(); Picker("表示", selection: $studio.preview) { Text("テキスト").tag(false); Text("スライド").tag(true) }.pickerStyle(.segmented).frame(width: 170) }
                HStack { Button { studio.slide -= 1 } label: { Image(systemName: "chevron.left") }.disabled(studio.slide <= 1); Picker("", selection: $studio.slide) { ForEach(studio.project?.slides ?? []) { Text("スライド \($0.number)").tag($0.number) } }.labelsHidden().frame(width: 140); Button { studio.slide += 1 } label: { Image(systemName: "chevron.right") }.disabled(studio.slide >= (studio.project?.slide_count ?? 0)); Spacer(); if !studio.drafts.isEmpty { Button("変更を保存", action: studio.saveEdits).buttonStyle(.borderedProminent).font(.caption) } }
                Divider()
                if studio.preview { previewPanel }
                else {
                    ForEach(studio.visibleUnits) { unit in NativeTextPair(unit: unit) }
                    if studio.visibleUnits.isEmpty { Text("このスライドに編集可能なテキストはありません。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30) }
                }
                Label("画像内の文字・数式・マスターは原文を保持します。複数書式の位置は近似して引き継ぎます。", systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var previewPanel: some View {
        VStack(spacing: 12) {
            HStack { Picker("表示", selection: $studio.translatedPreview) { Text("原本").tag(false); Text("翻訳後").tag(true) }.labelsHidden().frame(width: 120); Spacer(); Button("プレビューを作成", action: studio.renderPreview).disabled(studio.project?.preview_state == "rendering" || (studio.translatedPreview && !studio.canExport)) }
            if studio.project?.preview_state == "rendering" { ProgressView("スライドを描画しています…").frame(height: 260) }
            else if let image = studio.previewImage { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { VStack(spacing: 12) { Image(systemName: "rectangle.on.rectangle").font(.largeTitle); Text(studio.project?.preview_state == "error" ? studio.project?.preview_error ?? "" : "「プレビューを作成」でスライドを表示します。") }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 240).background(canvas) }
            if studio.translatedPreview && studio.previewImage != nil && (studio.project?.preview_state != "ready" || studio.project?.preview_version != "translated") {
                Text("訳文の変更を反映するには「プレビューを作成」を押してください。").font(.caption).foregroundStyle(.orange)
            }
            Text("LibreOfficeで描画します。PowerPointと表示が異なる場合があります。").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

struct NativeTextPair: View {
    @EnvironmentObject var studio: StudioModel
    let unit: TextUnit
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("ORIGINAL").font(.system(size: 9, weight: .medium)).tracking(1); Spacer(); Text(unit.kind == "notes" ? "ノート" : unit.kind.contains("chart") ? "グラフ" : "スライド").font(.system(size: 9)) }.foregroundStyle(.secondary)
            Text(unit.source).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: Binding(get: { studio.drafts[unit.id] ?? unit.translation }, set: { studio.drafts[unit.id] = $0 })).font(.system(size: 13)).scrollContentBackground(.hidden).padding(7).frame(minHeight: 55, idealHeight: CGFloat(max(55, min(190, (unit.translation.count / 45 + 1) * 23 + 25))))
                .background(accent.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 7)).disabled(studio.translating)
            Text(studio.drafts[unit.id] != nil ? "未保存の変更" : unit.status == "error" ? unit.error : unit.status == "preserved" ? "原文を保持" : unit.status == "done" ? "✓ 保存済み · 編集できます" : "翻訳前")
                .font(.system(size: 9)).foregroundStyle(unit.status == "error" ? Color.orange : accent.opacity(0.7))
            Divider().padding(.top, 8)
        }
    }
}

struct NativeChat: View {
    @EnvironmentObject var studio: StudioModel
    var body: some View {
        VStack(spacing: 0) {
            HStack { Label("資料と対話する", systemImage: "sparkles").font(.system(size: 14, weight: .semibold)); Spacer(); Button(action: studio.clearChat) { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless).disabled(studio.chatting).help("会話をクリア") }.padding(20)
            Divider()
            VStack(spacing: 12) { Picker("モデル", selection: $studio.chatModel) { ForEach(studio.chatModels) { Text($0.name).tag($0.name) } }; HStack { Toggle("資料を参照", isOn: $studio.useDocument).toggleStyle(.checkbox); Spacer(); Toggle("現在のスライド", isOn: $studio.currentSlideOnly).toggleStyle(.checkbox).disabled(!studio.useDocument) }.font(.system(size: 10)) }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView { LazyVStack(alignment: .leading, spacing: 18) {
                    if studio.bubbles.isEmpty { emptyChat }
                    ForEach(studio.bubbles) { bubble in
                        VStack(alignment: .leading, spacing: 7) {
                            if bubble.role == "assistant" { Text("LOCAL AI").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary) }
                            if bubble.text.isEmpty { ProgressView().controlSize(.small).padding(8) }
                            else { Text(bubble.text).font(.system(size: 12)).lineSpacing(5).foregroundStyle(bubble.failed ? Color.orange : Color.primary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                            if bubble.role == "assistant" && !bubble.refs.isEmpty { ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(bubble.refs, id: \.self) { number in Button("スライド \(number)") { studio.slide = number }.font(.system(size: 9)).buttonStyle(.bordered) } } } }
                        }.padding(bubble.role == "user" ? 12 : 2).frame(maxWidth: .infinity, alignment: .leading).background(bubble.role == "user" ? accent.opacity(0.075) : .clear).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.leading, bubble.role == "user" ? 20 : 0).id(bubble.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(17) }
                .onChange(of: studio.bubbles.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            VStack(spacing: 6) {
                TextEditor(text: $studio.chatInput).font(.system(size: 12)).scrollContentBackground(.hidden).frame(height: 58).padding(8).background(canvas).clipShape(RoundedRectangle(cornerRadius: 7)).overlay(alignment: .topLeading) { if studio.chatInput.isEmpty { Text("資料について質問する…").font(.system(size: 12)).foregroundStyle(.tertiary).padding(12).allowsHitTesting(false) } }
                HStack { Text("⌘ + Returnで送信").font(.system(size: 9)).foregroundStyle(.tertiary); Spacer(); Button { studio.chatting ? studio.stopChat() : studio.sendChat() } label: { Image(systemName: studio.chatting ? "stop.fill" : "arrow.up").frame(width: 22, height: 22) }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(!studio.chatting && (studio.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || studio.chatModel.isEmpty)) }
                Text("AIの回答は資料と照らし合わせて確認してください。").font(.system(size: 8)).foregroundStyle(.tertiary)
            }.padding(14)
        }.background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.07)))
    }
    private var emptyChat: some View {
        VStack(spacing: 15) {
            Image(systemName: "sparkles").font(.system(size: 33, weight: .light)).foregroundStyle(accent).padding(16).background(accent.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 17))
            Text("この資料を、もっと深く。").font(.system(size: 14, weight: .medium))
            Text("要点の整理から、訳語の相談まで。\nローカルAIが一緒に読み解きます。").font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            ForEach(["この資料の要点を3つにまとめて", "このスライドをわかりやすく説明して", "翻訳で注意すべき専門用語は？"], id: \.self) { question in Button { studio.chatInput = question } label: { Text(question).font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading).padding(8) }.buttonStyle(.bordered) }
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
@main struct SlideLocalNativeApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @StateObject private var studio = StudioModel()
    var body: some Scene {
        Window("Slide Local — PowerPoint翻訳", id: "studio") {
            StudioView().environmentObject(studio).preferredColorScheme(.light).frame(minWidth: 1100, minHeight: 760).task { delegate.studio = studio; await studio.start() }
        }.defaultSize(width: 1450, height: 970).windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) { Button("PowerPointを開く…", action: studio.chooseFile).keyboardShortcut("o"); Button("翻訳したPPTXを保存…", action: studio.exportPPTX).keyboardShortcut("s").disabled(!studio.canExport) }
        }
    }
}
