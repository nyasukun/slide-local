import Foundation

actor LookupGate: LocalInference {
    var calls = 0; var gate: CheckedContinuation<Void, Never>?; var blocked = false
    func models() async throws -> [LocalModel] {
        calls += 1
        if calls == 2 { blocked = true; await withCheckedContinuation { gate = $0 } }
        return [LocalModel(name: "plamo-translate:0.8b", size: 1, digest: "review")]
    }
    func isBlocked() -> Bool { blocked }
    func release() { gate?.resume(); gate = nil }
    func translate(_ text: String, target: String, model: String, source: String, context: String) async throws -> String { "訳: " + text }
    nonisolated func chat(model: String, messages: [[String: String]]) -> AsyncThrowingStream<ChatDelta, Error> { AsyncThrowingStream { $0.finish() } }
}
@main struct NativeReviewRegressions {
    static func until(_ condition: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while try await !condition() { if Date() > end { throw StudioError("regression timed out") }; try await Task.sleep(nanoseconds: 10_000_000) }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = URL(fileURLWithPath: CommandLine.arguments[2])
        if CommandLine.arguments[3] == "orphan" {
            let store = try ProjectStore(root: root)
            let engine = try NativeEngine(store: store)
            _ = try await engine.importFile(fixture)
            let orphan = root.appendingPathComponent(String(repeating: "c", count: 32))
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            try Data("partial source".utf8).write(to: orphan.appendingPathComponent("source.pptx"))
            let catalog = try store.list(); precondition(catalog.count == 1)
            let preserved = root.appendingPathComponent("incomplete-imports").appendingPathComponent(orphan.lastPathComponent).appendingPathComponent("source.pptx")
            let contents = try Data(contentsOf: preserved); precondition(contents == Data("partial source".utf8))
            print("interrupted import: existing catalog accessible, orphan bytes retained PASS")
            return
        }
        for clear in [false, true] {
            let sub = root.appendingPathComponent(clear ? "clear" : "save"), store = try ProjectStore(root: sub), inference = LookupGate()
            let engine = try NativeEngine(store: store, inference: inference)
            let p = try await engine.importFile(fixture)
            if clear { try await engine.recordChat(p.id, question: "before", answer: "retained?", refs: [1], model: "qwen") }
            try await engine.enqueue([p.id], options: QueueOptions(target: "ja", source: "", model: "plamo-translate:0.8b", notes: false, fit: true))
            try await until { await inference.isBlocked() }
            if clear { try await engine.clearChat(p.id) }
            else { try await engine.recordChat(p.id, question: "during lookup", answer: "must survive", refs: [1], model: "qwen") }
            await inference.release()
            try await until { await engine.queueSnapshot().items[0].status == "complete" }
            let live = try await engine.project(p.id); precondition(live.chats.count == (clear ? 0 : 1))
            let saved = try store.load(p.id); precondition(saved.chats.count == (clear ? 0 : 1))
        }
        print("model lookup reentrancy: recorded and cleared chat preserved PASS")
    }
}
