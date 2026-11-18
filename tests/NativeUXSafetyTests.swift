import Foundation

final class ExportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private let semaphore = DispatchSemaphore(value: 0)
    func hasEntered() -> Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func release() { semaphore.signal() }
    func write(source: URL, units: [TextUnit], fit: Bool, destination: URL) throws {
        lock.lock(); entered = true; lock.unlock()
        guard semaphore.wait(timeout: .now() + 20) == .success else { throw StudioError("export gate timeout") }
        try PPTX.export(source: source, units: units, fit: fit, destination: destination)
    }
}

// Breaks caught: unapproved/stale resets, cancellation before reset, unsafe legacy
// recovery, and repeating a committed reset after restart. Only inference is fake.
actor UXInference: LocalInference {
    var gateNext = false, entered = false
    var failAfterGate = false, available = true
    var gate: CheckedContinuation<Void, Never>?
    func blockModels(fail: Bool = false) { gateNext = true; entered = false; failAfterGate = fail }
    func setAvailable(_ value: Bool) { available = value }
    func hasEntered() -> Bool { entered }
    func release() { gate?.resume(); gate = nil }
    func models() async throws -> [LocalModel] {
        if gateNext {
            gateNext = false; entered = true; await withCheckedContinuation { gate = $0 }
            if failAfterGate { failAfterGate = false; throw StudioError("lookup disconnected") }
        }
        return available ? [LocalModel(name: "plamo-translate:0.8b", size: 1, digest: "ux-fixture"), LocalModel(name: "cat-translate:1.4b", size: 1, digest: "cat-fixture"), LocalModel(name: "translategemma:12b-it-q4_K_M", size: 1, digest: "gemma-fixture")] : []
    }
    func translate(_ text: String, target: String, model: String, source: String, context: String) async throws -> String { "訳: " + text }
    nonisolated func chat(model: String, messages: [[String: String]]) -> AsyncThrowingStream<ChatDelta, Error> { AsyncThrowingStream { $0.finish() } }
}

#if !STUDIO_TESTS
@main struct NativeUXSafetyTests {
    static func check(_ value: Bool, _ message: String) throws { if !value { throw StudioError(message) } }
    static func until(_ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while try await !predicate() {
            if Date() > deadline { throw StudioError("UX safety timeout") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    static func rejects(_ body: () async throws -> Void) async throws {
        do { try await body() } catch { return }
        throw StudioError("unsafe request accepted")
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = URL(fileURLWithPath: CommandLine.arguments[2])
        let store = try ProjectStore(root: root), inference = UXInference()
        let engine = try NativeEngine(store: store, inference: inference)
        try await engine.setPaused(true)
        let a = try await engine.importFile(fixture), b = try await engine.importFile(fixture)
        let ja = QueueOptions(target: "ja", source: "", model: "plamo-translate:0.8b", notes: false, fit: true)
        let en = QueueOptions(target: "en", source: "", model: "plamo-translate:0.8b", notes: false, fit: true)
        let unit = a.units.first { $0.kind != "notes" }!
        try await engine.edit(a.id, unit: unit.id, translation: "手動修正・消さない")
        try await rejects { try await engine.enqueue([a.id], options: en) }
        try check(try store.load(a.id).units.first { $0.id == unit.id }?.translation == "手動修正・消さない", "unapproved reset altered text")

        let assessment = try await engine.assessTranslation([a.id], options: en)
        try check(assessment[0].resetsTranslations && assessment[0].translatedCount == 1, "reset not assessed")
        try await engine.edit(a.id, unit: unit.id, translation: "確認後に更新")
        try await rejects { try await engine.enqueue([a.id], options: en, assessments: assessment, allowReset: true) }
        let current = try await engine.assessTranslation([a.id], options: en)
        try await engine.enqueue([a.id], options: en, assessments: current, allowReset: true)
        await inference.blockModels()
        try await engine.setPaused(false)
        try await until { await inference.hasEntered() }
        try await engine.cancelProject(a.id)
        await inference.release()
        try await until { await engine.queueSnapshot().items.last?.status == "cancelled" }
        try check(try store.load(a.id).units.first { $0.id == unit.id }?.translation == "確認後に更新", "stop during setup erased text")

        if let note = b.units.first(where: { $0.kind == "notes" }) {
            try await engine.edit(b.id, unit: note.id, translation: "発表者メモ手修正")
            let notes = try await engine.assessTranslation([b.id], options: en)
            try check(notes[0].resetsTranslations && notes[0].translatedCount == 1, "excluded notes were not protected")
        }

        // An old queued reset without approval must not erase anything or block
        // unrelated runnable documents after recovery.
        try await engine.setPaused(true)
        let c = try await engine.importFile(fixture)
        var legacy = try store.loadQueue()
        legacy.paused = false
        legacy.items.append(QueueItem(id: newID(), project_id: a.id, filename: a.filename, status: "queued", message: "", options: en))
        legacy.items.append(QueueItem(id: newID(), project_id: c.id, filename: c.filename, status: "queued", message: "", options: ja))
        try store.saveQueue(legacy)
        await engine.shutdown()
        let restored = try NativeEngine(store: store, inference: inference)
        await restored.start()
        try await until { !(await restored.queueSnapshot()).items.contains { ["queued", "running"].contains($0.status) } }
        let result = await restored.queueSnapshot()
        try check(result.items.suffix(2).map(\.status) == ["confirmation", "complete"], "legacy reset not held aside")
        try check(result.items[result.items.count - 2].completed == nil && result.items[result.items.count - 2].total == nil, "held request inherited previous progress")
        try check(try store.load(a.id).units.first { $0.id == unit.id }?.translation == "確認後に更新", "legacy reset erased text")

        // Simulate a crash after reset committed but before queue completion.
        // The marker and matching settings authorize resumption, not a new reset.
        var p = try store.load(a.id)
        let requestID = newID()
        p.source = ""; p.target = "en"; p.model = en.model; p.translation_request_id = requestID
        p.units[0].translation = "既に翻訳済み"; p.units[0].status = "done"
        try store.save(p)
        var recovery = try store.loadQueue()
        recovery.items.append(QueueItem(id: requestID, project_id: p.id, filename: p.filename, status: "running", message: "", options: en, approved_fingerprint: "pre-reset-fingerprint"))
        try store.saveQueue(recovery)
        await restored.shutdown()
        let resumed = try NativeEngine(store: store, inference: inference)
        await resumed.start()
        try await until { await resumed.queueSnapshot().items.last?.status == "complete" }
        try check(try store.load(p.id).units[0].translation == "既に翻訳済み", "recovery repeated reset")
        let completedHistory = await resumed.queueSnapshot().items.first { $0.project_id == c.id }!
        let exported = try await resumed.export(c.id), before = try Data(contentsOf: exported)
        let completeProject = try await resumed.project(c.id)
        try await resumed.edit(c.id, unit: completeProject.units[0].id, translation: "別の編集")
        let secondExport = try await resumed.export(c.id)
        try check(exported != secondExport && (try Data(contentsOf: exported)) == before, "export snapshot overwritten by rebuild")
        let laterHistory = await resumed.queueSnapshot().items.first { $0.id == completedHistory.id }!
        try check(laterHistory.completed == completedHistory.completed && laterHistory.total == completedHistory.total, "history progress changed with edits")
        let destination = root.appendingPathComponent("save.pptx")
        try atomicSave(exported, to: destination, overwrite: false)
        try await rejects { try atomicSave(secondExport, to: destination, overwrite: false) }
        try check(try Data(contentsOf: destination) == before, "batch export overwrote existing file")
        try FileManager.default.removeItem(at: exported); try FileManager.default.removeItem(at: secondExport)
        // A failed lookup must not override a stop explicitly requested while it
        // was in flight. Missing-model/setup failures have no previous run counts.
        try await resumed.setPaused(true)
        let stopAssessment = try await resumed.assessTranslation([a.id], options: ja)
        try await resumed.enqueue([a.id], options: ja, assessments: stopAssessment, allowReset: true)
        await inference.blockModels(fail: true)
        try await resumed.setPaused(false)
        try await until { await inference.hasEntered() }
        try await resumed.cancelProject(a.id); await inference.release()
        try await until { !(await resumed.queueSnapshot()).items.contains { ["queued", "running"].contains($0.status) } }
        try check(await resumed.queueSnapshot().items.last?.status == "cancelled", "lookup error overrode stop")
        try await resumed.setPaused(true)
        try await resumed.enqueue([c.id], options: ja)
        await inference.setAvailable(false)
        try await resumed.setPaused(false)
        try await until { await resumed.queueSnapshot().items.last?.status == "error" }
        let unavailable = await resumed.queueSnapshot().items.last!
        try check(unavailable.completed == nil && unavailable.total == nil, "setup failure inherited older run progress")
        await inference.setAvailable(true); await resumed.shutdown()

        let failureRoot = root.appendingPathComponent("save-failure")
        let failureStore = try ProjectStore(root: failureRoot)
        let initial = try NativeEngine(store: failureStore, inference: inference)
        try await initial.setPaused(true)
        let f = try await initial.importFile(fixture), g = try await initial.importFile(fixture)
        try await initial.enqueue([f.id, g.id], options: ja)
        var ready = try failureStore.loadQueue(); ready.paused = false; try failureStore.saveQueue(ready)
        await initial.shutdown()
        let recoveryEngine = try NativeEngine(store: failureStore, inference: inference)
        let queueFile = failureRoot.appendingPathComponent("queue.json"), backup = failureRoot.appendingPathComponent("queue-backup")
        try FileManager.default.moveItem(at: queueFile, to: backup)
        try FileManager.default.createDirectory(at: queueFile, withIntermediateDirectories: false)
        await recoveryEngine.start()
        try await until { await recoveryEngine.lastError != nil }
        try check(await recoveryEngine.queueSnapshot().items.map(\.status) == ["queued", "queued"], "failed admission stranded running item")
        try FileManager.default.removeItem(at: queueFile)
        try FileManager.default.moveItem(at: backup, to: queueFile)
        try await recoveryEngine.setPaused(false)
        try await until { await recoveryEngine.queueSnapshot().items.allSatisfy { $0.status == "complete" } }
        let recoveredOrder = await recoveryEngine.queueSnapshot()
        try check(recoveredOrder.items[0].finished! <= recoveredOrder.items[1].started!, "persistence retry broke FIFO")
        let buildStore = try ProjectStore(root: root.appendingPathComponent("build-stop")), buildGate = ExportGate()
        let buildEngine = try NativeEngine(store: buildStore, inference: inference, pptxWriter: { try buildGate.write(source: $0, units: $1, fit: $2, destination: $3) })
        let h = try await buildEngine.importFile(fixture)
        try await buildEngine.enqueue([h.id], options: ja)
        try await until { buildGate.hasEntered() }
        try await buildEngine.cancelProject(h.id); buildGate.release()
        try await until { !(await buildEngine.queueSnapshot()).items.contains { ["running", "queued"].contains($0.status) } }
        try check(await buildEngine.queueSnapshot().items.last?.status == "cancelled", "stop during final build reported complete")
        print("UX safety: unapproved/stale resets, excluded notes, setup stop, legacy hold, durable reset recovery PASS")
    }
}
#endif
