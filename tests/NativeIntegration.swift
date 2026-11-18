import Foundation

@main struct NativeIntegration {
    static func main() async throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[1]), inputA = URL(fileURLWithPath: args[2]), inputB = URL(fileURLWithPath: args[3])
        let client = OllamaClient(), store = try ProjectStore(root: root), engine = try NativeEngine(store: store, inference: client)
        let models = try await client.models(); precondition(models.contains { $0.name == "translategemma:12b-it-q4_K_M" })
        let cloud = try await client.cloudDisabled(); precondition(cloud)
        try await engine.setPaused(true)
        let a = try await engine.importFile(inputA), b = try await engine.importFile(inputB)
        precondition(a.model == "translategemma:12b-it-q4_K_M" && b.model == a.model)
        let options = QueueOptions(target: "ja", source: "", model: a.model, notes: false, fit: true)
        let start = Date()
        try await engine.enqueue([a.id, b.id], options: options); try await engine.setPaused(false)
        let deadline = Date().addingTimeInterval(180)
        var queue: QueueState
        repeat {
            queue = await engine.queueSnapshot()
            if !queue.items.contains(where: { ["queued", "running"].contains($0.status) }) { break }
            guard Date() < deadline else { throw StudioError("real queue timed out") }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while true
        precondition(queue.items.map { $0.status } == ["complete", "complete"])
        precondition(queue.items[0].finished! <= queue.items[1].started!)
        let p = try await engine.project(a.id), translated = p.units.filter { $0.kind != "notes" }.map { $0.translation }.joined(separator: "\n")
        precondition(translated.range(of: "[ぁ-んァ-ヶ一-龥]", options: .regularExpression) != nil)
        let (stream, refs) = try await engine.chat(a.id, model: "qwen3.5:4b", question: "売上は何パーセント増えましたか？", useDocument: true, slide: nil)
        var answer = "", done = false
        for try await delta in stream { answer += delta.text; done = done || delta.done }
        precondition(done && answer.contains("20"))
        try await engine.recordChat(a.id, question: "売上は何パーセント増えましたか？", answer: answer, refs: refs, model: "qwen3.5:4b")
        let regenerate = args.contains("--regenerate")
        if regenerate {
            let unit = p.units.first { $0.kind != "notes" && !PPTX.shouldPreserve($0.source) }!
            try await engine.edit(a.id, unit: unit.id, translation: "MANUAL_REGENERATION_SENTINEL")
            let assessment = try await engine.assessTranslation([a.id], options: options, regenerate: true)
            try await engine.enqueue([a.id], options: options, assessments: assessment, allowReset: true, regenerate: true)
            let regenerationDeadline = Date().addingTimeInterval(180)
            repeat {
                queue = await engine.queueSnapshot()
                if !queue.items.contains(where: { ["queued", "running"].contains($0.status) }) { break }
                guard Date() < regenerationDeadline else { throw StudioError("real regeneration timed out") }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while true
            precondition(queue.items.last?.status == "complete" && queue.items.last?.regenerate == true)
            let regenerated = try await engine.project(a.id)
            precondition(regenerated.units.first { $0.id == unit.id }?.translation != "MANUAL_REGENERATION_SENTINEL")
        }
        let output = try await engine.export(a.id)
        let skipPreview = args.contains("--skip-preview")
        var imagePath = ""
        if !skipPreview {
            try await engine.preview(a.id, translated: true)
            while try await engine.project(a.id).preview_state == "rendering" { try await Task.sleep(nanoseconds: 100_000_000) }
            let previewProject = try await engine.project(a.id)
            guard previewProject.preview_state == "ready" else { throw StudioError(previewProject.preview_error) }
            imagePath = try await engine.previewImage(a.id, translated: true, slide: 1).path
        }
        let receipt: [String: Any] = ["cloud_disabled": cloud, "queue": try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)), "translation": translated, "answer": answer, "refs": refs, "output": output.path, "preview": imagePath, "preview_performed": !skipPreview, "regeneration_performed": regenerate, "seconds": Date().timeIntervalSince(start), "chats": (try await engine.project(a.id)).chats.count]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: root.appendingPathComponent("real-native-check.json")); print(String(data: data, encoding: .utf8)!)
    }
}
