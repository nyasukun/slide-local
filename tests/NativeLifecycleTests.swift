import Foundation

actor ControlledInference: LocalInference {
    var block = true, entered = false, failOnce = false
    var gate: CheckedContinuation<Void, Never>?
    func models() async throws -> [LocalModel] { [LocalModel(name: "plamo-translate:0.8b", size: 1, digest: newID())] }
    func translate(_ text: String, target: String, model: String, source: String, context: String) async throws -> String {
        if block { block = false; entered = true; await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        if failOnce { failOnce = false; throw StudioError("model error") }
        return "翻訳: " + text
    }
    func release() { gate?.resume(); gate = nil }
    func didEnter() -> Bool { entered }
    func failureOnNext() { failOnce = true }
    func disableGate() { block = false }
    nonisolated func chat(model: String, messages: [[String: String]]) -> AsyncThrowingStream<ChatDelta, Error> { AsyncThrowingStream { $0.finish() } }
}
@main struct NativeLifecycleTests {
    static func until(_ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while try await !predicate() { guard Date() < deadline else { throw StudioError("lifecycle timeout") }; try await Task.sleep(nanoseconds: 10_000_000) }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = URL(fileURLWithPath: CommandLine.arguments[2])
        let options = QueueOptions(target: "ja", source: "", model: "plamo-translate:0.8b", notes: false, fit: true)
        let inference = ControlledInference(), store = try ProjectStore(root: root), engine = try NativeEngine(store: store, inference: inference)
        try await engine.setPaused(true)
        let a = try await engine.importFile(fixture), b = try await engine.importFile(fixture)
        try await engine.enqueue([a.id,b.id], options: options); try await engine.setPaused(false)
        try await until { await inference.didEnter() }
        try await engine.setPaused(true)
        let running = await engine.queueSnapshot(); try await engine.cancel(running.items[0].id)
        await inference.release()
        try await until { await engine.queueSnapshot().items[0].status == "cancelled" }
        let paused = await engine.queueSnapshot(); precondition(paused.items[1].status == "queued")
        try await engine.setPaused(false)
        try await until { await engine.queueSnapshot().items[1].status == "complete" }
        let partial = try await engine.project(a.id); precondition(partial.units.contains { $0.status == "done" })
        // A failure in one document must not prevent the next document from completing.
        let c = try await engine.importFile(fixture), d = try await engine.importFile(fixture)
        await inference.failureOnNext(); try await engine.enqueue([c.id,d.id], options: options)
        try await until { !(await engine.queueSnapshot()).items.contains { ["running","queued"].contains($0.status) } }
        let failed = await engine.queueSnapshot(); precondition(failed.items.suffix(2).map { $0.status } == ["review","complete"])
        // Quit while a request is outstanding. Persist running, recover into queued on restart.
        let recoveryRoot = root.appendingPathComponent("recovery"), recoveryStore = try ProjectStore(root: recoveryRoot)
        let blocked = ControlledInference(), first = try NativeEngine(store: recoveryStore, inference: blocked)
        let e = try await first.importFile(fixture)
        try await first.enqueue([e.id], options: options)
        try await until { await blocked.didEnter() }
        await first.shutdown(); await blocked.release()
        try await until { try recoveryStore.load(e.id).state == "interrupted" }
        let persisted = try recoveryStore.loadQueue(); precondition(persisted.items[0].status == "running")
        let quick = ControlledInference(); await quick.disableGate()
        let restored = try NativeEngine(store: recoveryStore, inference: quick)
        let recovered = await restored.queueSnapshot(); precondition(recovered.items[0].status == "queued")
        await restored.start()
        try await until { await restored.queueSnapshot().items[0].status == "complete" }
        // A persisted explicit cancel request is restored as cancelled, never restarted.
        var saved = try recoveryStore.loadQueue(); saved.items[0].status = "running"; saved.items[0].cancel_requested = true
        try recoveryStore.saveQueue(saved)
        let stopped = try NativeEngine(store: recoveryStore, inference: quick)
        let stopState = await stopped.queueSnapshot(); precondition(stopState.items[0].status == "cancelled")
        print("native lifecycle: running cancel, document-boundary pause, failure continuation, quit/restart checkpoint, pending cancellation recovery PASS")
    }
}
