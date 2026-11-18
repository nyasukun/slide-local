import Foundation

actor RegenerationInference: LocalInference {
    var calls = 0, failNext = false, holdNext = false, entered = false
    var gate: CheckedContinuation<Void, Never>?
    func models() async throws -> [LocalModel] {
        ["cat-translate:1.4b", "translategemma:12b-it-q4_K_M"].map { LocalModel(name: $0, size: 1, digest: "stable") }
    }
    func translate(_ text: String, target: String, model: String, source: String, context: String) async throws -> String {
        calls += 1
        if holdNext { holdNext = false; entered = true; await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        if failNext { failNext = false; throw StudioError("ambiguous translation fixture") }
        return "新訳\(calls):" + text
    }
    func count() -> Int { calls }
    func fail() { failNext = true }
    func hold() { entered = false; holdNext = true }
    func didEnter() -> Bool { entered }
    func release() { gate?.resume(); gate = nil }
    nonisolated func chat(model: String, messages: [[String: String]]) -> AsyncThrowingStream<ChatDelta, Error> { AsyncThrowingStream { $0.finish() } }
}

@main struct NativeRegenerationTests {
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw StudioError(message) } }
    static func until(_ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while try await !predicate() {
            guard Date() < deadline else { throw StudioError("regeneration timeout") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    static func wait(_ engine: NativeEngine) async throws {
        try await until { !(await engine.queueSnapshot()).items.contains { ["queued", "running"].contains($0.status) } }
    }
    static func main() async throws {
        let store = try ProjectStore(root: URL(fileURLWithPath: CommandLine.arguments[1]))
        let inference = RegenerationInference(), engine = try NativeEngine(store: store, inference: inference)
        let p = try await engine.importFile(URL(fileURLWithPath: CommandLine.arguments[2]))
        let model = CommandLine.arguments.contains("--gemma") ? "translategemma:12b-it-q4_K_M" : "cat-translate:1.4b"
        let options = QueueOptions(target: "ja", source: "", model: model, notes: false, fit: true)
        let selected = p.units.filter { $0.kind != "notes" }
        for unit in selected {
            let neighbors = selected.filter { $0.slides.first == unit.slides.first && $0.id != unit.id }.map(\.source).joined(separator: "\n")
            let context = String(String.UnicodeScalarView(neighbors.unicodeScalars.prefix(350)))
            let oldKey = try ProjectStore.cacheKey(digest: "stable", target: "ja", source: "", context: context, text: unit.source)
            try store.cachePut(oldKey, value: "OLD COMMENTARY CACHE")
            let priorOutputKey = try ProjectStore.cacheKey(digest: "stable:cat-output-v2", target: "ja", source: "", context: context, text: unit.source)
            try store.cachePut(priorOutputKey, value: "OLD COMMENTARY CACHE")
            let priorBraceKey = try ProjectStore.cacheKey(digest: "stable:cat-output-v3", target: "ja", source: "", context: context, text: unit.source)
            try store.cachePut(priorBraceKey, value: "OLD COMMENTARY CACHE")
        }
        try await engine.enqueue([p.id], options: options)
        try await wait(engine)
        let first = try await engine.project(p.id)
        try check(first.state == "complete" && !first.units.contains { $0.translation == "OLD COMMENTARY CACHE" }, "old generic/model output cache reused: \(model)")
        let firstCount = await inference.count()
        try check(firstCount > 0, "old cache was not bypassed")
        let unit = first.units.first { $0.kind != "notes" && !PPTX.shouldPreserve($0.source) }!
        try await engine.edit(p.id, unit: unit.id, translation: "手修正は成功まで保持")
        let note = first.units.first { $0.kind == "notes" }!
        try await engine.edit(p.id, unit: note.id, translation: "対象外ノート")
        let assessment = try await engine.assessTranslation([p.id], options: options, regenerate: true)
        try check(assessment[0].resetsTranslations && assessment[0].regenerate, "regeneration does not require confirmation")
        do {
            try await engine.enqueue([p.id], options: options, regenerate: true)
            throw StudioError("unconfirmed regeneration accepted")
        } catch let e as StudioError { try check(e.message != "unconfirmed regeneration accepted", e.message) }
        try await engine.setPaused(true)
        try await engine.enqueue([p.id], options: options, assessments: assessment, allowReset: true, regenerate: true)
        let queued = await engine.queueSnapshot().items.last!
        try check(queued.regenerate == true, "regeneration flag not persisted")
        try await engine.cancel(queued.id)
        try check(try await engine.project(p.id).units.first { $0.id == unit.id }?.translation == "手修正は成功まで保持", "queued cancel removed manual translation")
        try await engine.enqueue([p.id], options: options, assessments: assessment, allowReset: true, regenerate: true)
        await inference.fail()
        try await engine.setPaused(false)
        try await wait(engine)
        let failed = try await engine.project(p.id)
        try check(failed.state == "review", "failed regeneration marked complete")
        let retained = failed.units.first { $0.id == unit.id }!
        try check(retained.translation == "手修正は成功まで保持" && retained.status == "error" && retained.regenerate_pending == true, "failed regeneration erased previous translation or lost bypass intent")
        try check(failed.units.first { $0.id == note.id }?.translation == "対象外ノート", "excluded notes regenerated")
        try check(await inference.count() > firstCount, "regeneration used cached output")
        let failedCount = await inference.count()
        try await engine.enqueue([p.id], options: options)
        try await wait(engine)
        let resumed = try await engine.project(p.id)
        try check(await inference.count() > failedCount, "unfinished regeneration retry restored stale cache without inference")
        try check(resumed.units.first { $0.id == unit.id }?.translation != first.units.first { $0.id == unit.id }?.translation, "unfinished regeneration retry restored initial cached text")
        try check(resumed.units.first { $0.id == unit.id }?.regenerate_pending == nil, "successful generation did not clear pending bypass")
        let stale = try await engine.assessTranslation([p.id], options: options, regenerate: true)
        try await engine.edit(p.id, unit: unit.id, translation: "確認後の変更")
        do {
            try await engine.enqueue([p.id], options: options, assessments: stale, allowReset: true, regenerate: true)
            throw StudioError("stale regeneration accepted")
        } catch let e as StudioError { try check(e.message != "stale regeneration accepted", e.message) }
        let current = try await engine.assessTranslation([p.id], options: options, regenerate: true)
        await inference.hold()
        try await engine.enqueue([p.id], options: options, assessments: current, allowReset: true, regenerate: true)
        try await until { await inference.didEnter() }
        try check(try await engine.project(p.id).units.first { $0.id == unit.id }?.translation == "確認後の変更", "in-flight regeneration removed previous translation")
        await engine.shutdown(); await inference.release()
        try await until { try store.load(p.id).state == "interrupted" }
        let restored = try NativeEngine(store: store, inference: RegenerationInference())
        await restored.start()
        try await wait(restored)
        let complete = try await restored.project(p.id)
        try check(complete.state == "complete", "regeneration restart lost approval or failed")
        try check(complete.units.first { $0.id == unit.id }?.translation != "確認後の変更", "successful regeneration did not replace old translation")
        try check(complete.units.first { $0.id == note.id }?.translation == "対象外ノート", "restart changed excluded note")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queued)) as! [String: Any]
        json.removeValue(forKey: "regenerate")
        let legacy = try JSONDecoder().decode(QueueItem.self, from: JSONSerialization.data(withJSONObject: json))
        try check(legacy.regenerate == nil, "old queue JSON incompatible")
        var oldUnit = try JSONSerialization.jsonObject(with: JSONEncoder().encode(retained)) as! [String: Any]
        oldUnit.removeValue(forKey: "regenerate_pending")
        let decodedUnit = try JSONDecoder().decode(TextUnit.self, from: JSONSerialization.data(withJSONObject: oldUnit))
        try check(decodedUnit.regenerate_pending == nil, "old text-unit JSON incompatible")
        print("regeneration (\(model)): confirmation, versioned cache, bypass, failure retention, notes, stale consent, restart, legacy JSON PASS")
    }
}
