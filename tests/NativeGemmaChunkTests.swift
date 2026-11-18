import Foundation

actor GemmaChunkInference: LocalInference {
    var texts: [String] = []
    var failSecond = true
    func models() async throws -> [LocalModel] {
        [LocalModel(name: "translategemma:12b-it-q4_K_M", size: 1, digest: "chunks-fixture")]
    }
    func translate(_ text: String, target: String, model: String, source: String, context: String) async throws -> String {
        texts.append(text)
        guard text.utf8.count <= 480 else { throw StudioError("Gemma engine sent oversized chunk") }
        if failSecond && texts.count == 2 { throw StudioError("second chunk fixture failure") }
        return "訳\(texts.count)"
    }
    func history() -> [String] { texts }
    func succeed() { failSecond = false; texts = [] }
    nonisolated func chat(model: String, messages: [[String: String]]) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@main struct NativeGemmaChunkTests {
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw StudioError(message) } }
    static func wait(_ engine: NativeEngine) async throws {
        let deadline = Date().addingTimeInterval(20)
        while await engine.queueSnapshot().items.contains(where: { ["queued", "running"].contains($0.status) }) {
            guard Date() < deadline else { throw StudioError("chunk test timeout") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    static func main() async throws {
        let store = try ProjectStore(root: URL(fileURLWithPath: CommandLine.arguments[1]))
        let inference = GemmaChunkInference()
        let importer = try NativeEngine(store: store, inference: inference)
        var p = try await importer.importFile(URL(fileURLWithPath: CommandLine.arguments[2]))
        let paragraph = p.units.first { $0.kind != "notes" && !PPTX.shouldPreserve($0.source) }!
        // Only one paragraph participates: later independent fixture paragraphs
        // must not affect assertions about the second chunk of this paragraph.
        p.units = [paragraph]
        for i in p.slides.indices { p.slides[i].units = p.slides[i].units.filter { $0 == paragraph.id } }
        for i in p.units.indices { p.units[i].status = "done"; p.units[i].translation = "既存の確定訳" }
        let index = 0
        let text = String(repeating: "Every action needs approval before deployment. Keep the verified backup and record the decision. ", count: 14)
        p.units[index].source = text
        try store.save(p)
        // Fresh engine reads the saved legacy/manual text, not importer's cache.
        let engine = try NativeEngine(store: store, inference: inference)
        let options = QueueOptions(target: p.target, source: p.source, model: p.model, notes: false, fit: p.fit)
        let assessment = try await engine.assessTranslation([p.id], options: options, regenerate: true)
        try await engine.enqueue([p.id], options: options, assessments: assessment, allowReset: true, regenerate: true)
        try await wait(engine)
        let failed = try await engine.project(p.id)
        let attempted = await inference.history()
        try check(attempted.count == 2 && attempted.allSatisfy { $0.utf8.count <= 480 }, "engine did not split Gemma paragraph before inference")
        try check(failed.units[index].translation == "既存の確定訳" && failed.units[index].status == "error" && failed.units[index].regenerate_pending == true, "later chunk failure committed partial translation or lost previous text")
        await inference.succeed()
        try await engine.enqueue([p.id], options: options)
        try await wait(engine)
        let complete = try await engine.project(p.id)
        let translatedChunks = await inference.history()
        try check(translatedChunks.count >= 3 && translatedChunks.joined() == text, "retry reused partial cache or lost source chunks")
        try check(complete.state == "complete" && complete.units[index].translation.hasPrefix("訳1") && complete.units[index].regenerate_pending == nil, "all chunks did not commit atomically on success")
        print("Gemma chunks: <=480-byte inputs, second-chunk failure retention, no partial cache, full-source retry PASS")
    }
}
