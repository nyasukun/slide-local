import Foundation

actor TestInference: LocalInference {
    var calls: [String] = []
    func models() async throws -> [LocalModel] { [LocalModel(name: "plamo-translate:0.8b", size: 1, digest: "native-test")] }
    func translate(_ text: String, target: String, model: String, source: String, context: String) async throws -> String { calls.append(text); await Task.yield(); return "訳: " + text }
    nonisolated func chat(model: String, messages: [[String: String]]) -> AsyncThrowingStream<ChatDelta, Error> { AsyncThrowingStream { $0.yield(ChatDelta(text: "回答", done: true)); $0.finish() } }
    func count() -> Int { calls.count }
}
@main struct NativeEngineTests {
    static func wait(_ engine: NativeEngine) async throws -> QueueState {
        let deadline = Date().addingTimeInterval(15)
        while true {
            let q = await engine.queueSnapshot()
            if !q.items.contains(where: { ["queued", "running"].contains($0.status) }) { return q }
            if Date() > deadline { throw StudioError("queue timeout") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = URL(fileURLWithPath: CommandLine.arguments[2])
        let store = try ProjectStore(root: root), inference = TestInference()
        let engine = try NativeEngine(store: store, inference: inference)
        try await engine.setPaused(true)
        let a = try await engine.importFile(fixture), b = try await engine.importFile(fixture)
        let options = QueueOptions(target: "ja", source: "", model: "plamo-translate:0.8b", notes: false, fit: true)
        try await engine.enqueue([a.id, b.id], options: options)
        do { try await engine.enqueue([a.id], options: options); throw StudioError("duplicate allowed") } catch let e as StudioError { precondition(e.message != "duplicate allowed") }
        do { try await engine.edit(a.id, unit: a.units[0].id, translation: "bad"); throw StudioError("edit allowed") } catch let e as StudioError { precondition(e.message != "edit allowed") }
        let pending = await engine.queueSnapshot(); precondition(pending.items.count == 2 && pending.paused)
        try await engine.setPaused(false)
        let result = try await wait(engine)
        precondition(result.items.map { $0.status } == ["complete", "complete"])
        precondition(result.items[0].finished! <= result.items[1].started!)
        let firstCount = await inference.count()
        try await engine.enqueue([a.id], options: options)
        _ = try await wait(engine)
        let afterCount = await inference.count(); precondition(firstCount == afterCount)
        try await engine.setPaused(true)
        try await engine.enqueue([a.id], options: options)
        let q = await engine.queueSnapshot(); try await engine.cancel(q.items.last!.id)
        let cancelled = await engine.queueSnapshot(); precondition(cancelled.items.last!.status == "cancelled")
        let path = try await engine.export(a.id); precondition(FileManager.default.fileExists(atPath: path.path))
        try await engine.clearChat(a.id)
        print("native queue: FIFO, single worker, duplicate atomicity, edit lock, pause/cancel, cache reuse and PPTX export PASS")
    }
}
