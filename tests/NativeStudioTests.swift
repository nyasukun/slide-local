import Foundation

final class StudioChatInference: LocalInference, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation?
    func models() async throws -> [LocalModel] { [LocalModel(name: "qwen3.5:4b", size: 1), LocalModel(name: "plamo-translate:0.8b", size: 1)] }
    func translate(_ text: String, target: String, model: String, source: String, context: String) async throws -> String { "訳" }
    func chat(model: String, messages: [[String: String]]) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { value in lock.lock(); continuation = value; lock.unlock() }
    }
    func finish() { lock.lock(); let value = continuation; lock.unlock(); value?.yield(ChatDelta(text: "回答", done: true)); value?.finish() }
    func isReady() -> Bool { lock.lock(); defer { lock.unlock() }; return continuation != nil }
}

@main struct NativeStudioTests {
    @MainActor static func check(_ value: Bool, _ message: String) throws { if !value { throw StudioError(message) } }
    @MainActor static func until(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate() {
            if Date() > deadline { throw StudioError("studio timeout") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    @MainActor static func main() async throws {
        let store = try ProjectStore(root: URL(fileURLWithPath: CommandLine.arguments[1]))
        let engine = try NativeEngine(store: store, inference: UXInference())
        try await engine.setPaused(true)
        let a = try await engine.importFile(URL(fileURLWithPath: CommandLine.arguments[2]))
        let b = try await engine.importFile(URL(fileURLWithPath: CommandLine.arguments[2]))
        let studio = StudioModel(engine: engine)
        try await studio.selectProject(a.id)
        let first = a.units.first { $0.kind != "notes" }!
        studio.drafts[first.id] = "手で修正した文章"
        let en = QueueOptions(target: "en", source: "", model: a.model, notes: false, fit: true)
        studio.requestTranslation(ids: [a.id], options: en)
        try await until { studio.pendingTranslation != nil }
        try check(studio.actionBusy, "confirmation did not lock editing")
        try check(try store.load(a.id).units.first { $0.id == first.id }?.translation == "手で修正した文章", "draft omitted from confirmation assessment")
        let request = studio.pendingTranslation!
        try await studio.selectProject(b.id)
        try check(studio.project?.id == a.id, "selection changed during confirmation")
        studio.dismissTranslation(request)
        try check(!studio.actionBusy && studio.pendingTranslation == nil, "cancel left operation locked")
        try check(await engine.queueSnapshot().items.isEmpty, "cancel enqueued work")

        studio.requestTranslation(ids: [a.id, b.id], options: en)
        try await until { studio.pendingTranslation != nil }
        let batch = studio.pendingTranslation!
        try check(batch.assessments.count == 2 && batch.assessments.first?.resetsTranslations == true, "batch omitted reset assessment")
        studio.confirmTranslation(batch)
        studio.confirmTranslation(batch)
        try await until { !studio.actionBusy }
        try check(await engine.queueSnapshot().items.count == 2, "double confirmation duplicated work")
        for item in await engine.queueSnapshot().items { try await engine.cancel(item.id) }

        try await studio.selectProject(b.id)
        studio.drafts[b.units[0].id] = "別資料の未保存文章"
        try await studio.saveDrafts(projectID: a.id, changes: [first.id: "固定した対象への修正"])
        try check(studio.drafts[b.units[0].id] == "別資料の未保存文章", "saving other document removed current drafts")
        try check(try store.load(a.id).units.first { $0.id == first.id }?.translation == "固定した対象への修正", "fixed target not saved")
        studio.drafts = [b.units[0].id: "  "]
        studio.requestTranslation(ids: [b.id], options: en)
        try await until { !studio.actionBusy }
        try check(studio.error != nil && studio.pendingTranslation == nil, "blank draft did not stop admission")
        try check(await engine.queueSnapshot().items.count == 2, "save failure enqueued work")
        studio.drafts = [:]; studio.error = nil
        studio.translationModel = "missing-model"
        await studio.refreshModels()
        try check(studio.translationModel == "missing-model", "missing model silently replaced")
        let oldRun = QueueItem(id: newID(), project_id: a.id, filename: a.filename, status: "cancelled", message: "", options: en)
        studio.retryQueue(oldRun)
        try await until { studio.pendingTranslation != nil }
        try check(studio.pendingTranslation?.options.target == "en" && studio.pendingTranslation?.ids == [a.id], "retry did not use displayed history settings")
        studio.dismissTranslation(studio.pendingTranslation!)
        studio.drafts = [b.units[0].id: "先に保存される文章", "zz-missing-unit": "存在しない文章"]
        do { try await studio.saveDrafts(); throw StudioError("partial failure accepted") }
        catch let e as StudioError { try check(e.message != "partial failure accepted", e.message) }
        try check(studio.drafts[b.units[0].id] == nil && studio.drafts["zz-missing-unit"] != nil, "partial failure lost unsaved text")
        let chatStore = try ProjectStore(root: store.root.appendingPathComponent("chat"))
        let chatInference = StudioChatInference(), chatEngine = try NativeEngine(store: chatStore, inference: chatInference)
        let deck = try await chatEngine.importFile(URL(fileURLWithPath: CommandLine.arguments[2]))
        let chatStudio = StudioModel(engine: chatEngine)
        try await chatStudio.selectProject(deck.id)
        await chatStudio.refreshModels()
        chatStudio.chatInput = String(repeating: "a", count: 6000)
        try check(chatStudio.chatBlockReason == nil, "6000 scalar question blocked")
        chatStudio.chatInput += "b"
        try check(chatStudio.chatBlockReason != nil, "6001 scalar question accepted")
        chatStudio.chatInput = "質問"
        chatStudio.sendChat()
        try await until { chatInference.isReady() && !chatStudio.actionBusy }
        chatStudio.stopChat()
        chatInference.finish()
        try await until { !chatStudio.chatting }
        try check(try chatStore.load(deck.id).chats.isEmpty, "stopped exchange persisted")
        try await chatEngine.recordChat(deck.id, question: "完了した質問", answer: "回答", refs: [1], model: "qwen3.5:4b")
        await chatStudio.refreshCurrent()
        let oldGeneration = chatStudio.project?.chat_generation ?? ""
        chatStudio.clearChat()
        try check(chatStudio.pendingChatDeletion != nil && (try chatStore.load(deck.id)).chats.count == 1, "history deleted before confirmation")
        chatStudio.confirmChatDeletion(chatStudio.pendingChatDeletion!)
        try await until { !chatStudio.actionBusy }
        try check(try chatStore.load(deck.id).chats.isEmpty, "confirmed deletion failed")
        do {
            try await chatEngine.recordChat(deck.id, question: "遅れた回答", answer: "復活禁止", refs: [], model: "qwen3.5:4b", expectedGeneration: oldGeneration)
            throw StudioError("late answer accepted")
        } catch let e as StudioError { try check(e.message != "late answer accepted", e.message) }
        try check(try chatStore.load(deck.id).chats.isEmpty, "deleted history recreated")
        var imageProject = chatStudio.project!
        imageProject.translated_preview = PreviewRecord(state: "ready", fingerprint: try TranslationPolicy.previewFingerprint(imageProject, translated: true))
        chatStudio.project = imageProject; chatStudio.translatedPreview = true
        try check(chatStudio.previewFreshness.contains("最新"), "matching preview not recognized")
        chatStudio.drafts[deck.units[0].id] = "画像に未反映"
        try check(chatStudio.previewFreshness.contains("更新"), "draft change did not mark preview stale")
        // A completed answer has a short, non-cancellable atomic-save phase.
        chatStudio.chatting = true; chatStudio.chatFinalizing = true
        chatStudio.bubbles = [ChatBubble(role: "assistant", text: "完了した回答")]
        chatStudio.stopChat()
        try check(chatStudio.bubbles[0].text == "完了した回答" && chatStudio.chatting, "save-in-progress falsely accepted stop")
        chatStudio.chatFinalizing = false; chatStudio.chatting = false
        let cancelledRecord = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await chatEngine.recordChat(deck.id, question: "取消済み", answer: "保存しない", refs: [], model: "qwen3.5:4b", expectedGeneration: chatStudio.project?.chat_generation ?? "")
        }
        do { try await cancelledRecord.value; throw StudioError("cancelled persistence accepted") }
        catch { try check(try chatStore.load(deck.id).chats.isEmpty, "cancelled record persisted") }

        let settingStore = try ProjectStore(root: store.root.appendingPathComponent("running-options"))
        let settingInference = UXInference(), settingEngine = try NativeEngine(store: settingStore, inference: settingInference)
        try await settingEngine.setPaused(true)
        let settingDeck = try await settingEngine.importFile(URL(fileURLWithPath: CommandLine.arguments[2]))
        try await settingEngine.enqueue([settingDeck.id], options: en)
        await settingInference.blockModels(); try await settingEngine.setPaused(false)
        let deadline = Date().addingTimeInterval(15)
        while !(await settingInference.hasEntered()) { if Date() > deadline { throw StudioError("lookup gate timeout") }; await Task.yield() }
        let settingStudio = StudioModel(engine: settingEngine)
        try await settingStudio.selectProject(settingDeck.id)
        try check(settingStudio.currentOptions.target == "en", "running setup showed previous settings")
        await settingInference.release()
        while await settingEngine.queueSnapshot().items.last?.status != "complete" { if Date() > deadline { throw StudioError("completion timeout") }; try await Task.sleep(nanoseconds: 5_000_000) }
        await settingStudio.refreshCurrent(); await settingStudio.refreshQueue()
        try check(settingStudio.currentOptions.target == "en" && settingStudio.canExport, "finished request left stale unapplied editor options")
        print("Studio actions: fixed targets, draft assessment, cancellation, batch confirmation, duplicate guard, blank draft failure, missing model PASS")
    }
}
