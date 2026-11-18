import Foundation

// Opt-in real inference check: synthetic inputs only, no user documents.
// Usage: gemma-smoke <short-English cases.json> <output.json>
@main struct NativeGemmaSmoke {
    static func main() async throws {
        let casesURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        var cases = try JSONSerialization.jsonObject(with: Data(contentsOf: casesURL)) as! [[String: Any]]
        cases += ["Agenda", "Introduction", "Overview", "Questions?"].enumerated().map {
            ["id": "auto-\($0.offset)", "source": $0.element, "language": ""]
        }
        cases.append(["id": "ja-en", "source": "人間の判断を支援し、最終的な責任は担当者が負います。", "language": "ja", "target": "en"])
        let client = OllamaClient()
        var results: [[String: Any]] = []
        for item in cases {
            let text = item["source"] as! String
            let language = item["language"] as? String ?? "en"
            let target = item["target"] as? String ?? "ja"
            let start = Date()
            let chunks = OllamaClient.splitText(text, limit: 480)
            var translated: [String] = []
            for chunk in chunks {
                translated.append(try await client.translate(chunk, target: target, model: "translategemma:12b-it-q4_K_M",
                                                              source: language, context: "DO_NOT_LEAK_NEIGHBOR: November 10, 2026"))
            }
            let value = translated.joined(separator: target == "en" ? " " : "")
            guard !value.contains("DO_NOT_LEAK_NEIGHBOR"), !value.contains("November 10, 2026") else {
                throw StudioError("reference context leaked")
            }
            for literal in ["https://example.com/docs?v=2&lang=en", "{customer_name}", "%s"] where text.contains(literal) {
                guard value.contains(literal) else { throw StudioError("protected source literal changed: \(literal)") }
            }
            let row: [String: Any] = ["id": item["id"]!, "source": text, "source_language": language,
                                      "target": target, "translation": value, "seconds": Date().timeIntervalSince(start),
                                      "input_bytes": text.utf8.count, "chunks": chunks.count,
                                      "max_chunk_bytes": chunks.map { $0.utf8.count }.max() ?? 0]
            results.append(row)
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: outputURL, options: .atomic)
            print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!)
        }
        print("Real OllamaClient Gemma smoke: \(results.count) outputs saved; semantic review required.")
    }
}
