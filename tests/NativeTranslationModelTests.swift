import Foundation

// Only HTTP transport is replaced: request construction and local preflight are real.
final class TranslationProtocol: URLProtocol, @unchecked Sendable {
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []
    static var disabled = true
    static var remote = false
    static var reason = "stop"
    static var reply = "会議は月曜日です。"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.bodies.append(body)
        let value: [String: Any]
        switch request.url!.path {
        case "/api/status": value = ["cloud": ["disabled": Self.disabled]]
        case "/api/tags":
            value = ["models": ["cat-translate:1.4b", "plamo-translate:0.8b", "translategemma:12b-it-q4_K_M"].map {
                ["name": $0, "size": 1, "digest": "fixture", "remote_host": Self.remote ? "https://invalid.example" : ""]
            }]
        default: value = ["message": ["role": "assistant", "content": Self.reply], "done": true, "done_reason": Self.reason]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct NativeTranslationModelTests {
    static func main() async throws {
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) { if !condition { failures.append(name); print("FAIL: \(name)") } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranslationProtocol.self]
        let client = OllamaClient(configuration: config)
        let gemma = "translategemma:12b-it-q4_K_M"
        check(LocalModel.defaultTranslation == gemma, "new project defaults to verified Gemma model")
        check(LocalModel.isTranslationOnly(gemma), "Gemma cannot be offered for conversation")
        check(LocalModel.translationCacheDigest("weights", model: gemma) == "weights:translategemma-single-v1", "old generic Gemma cache is isolated")
        for (text, source, target, sourceName, sourceCode, targetName, targetCode) in [
            ("Agenda", "", "ja", "English", "en", "Japanese", "ja"),
            ("Introduction", "", "ja", "English", "en", "Japanese", "ja"),
            ("Overview", "", "ja", "English", "en", "Japanese", "ja"),
            ("会社概要", "", "en", "Japanese", "ja", "English", "en"),
            ("会議は来週の月曜日です。", "", "en", "Japanese", "ja", "English", "en"),
            ("Hello.", "en", "zh-hans", "English", "en", "Chinese", "zh-Hans"),
            ("Hello.", "en", "zh-hant", "English", "en", "Chinese", "zh-Hant"),
            ("Hello.", "en", "ko", "English", "en", "Korean", "ko"),
            ("Hello.", "en", "fr", "English", "en", "French", "fr"),
            ("Hello.", "en", "de", "English", "en", "German", "de"),
            ("Hello.", "en", "es", "English", "en", "Spanish", "es"),
            ("Bonjour.", "fr", "ja", "French", "fr", "Japanese", "ja"),
            ("這是一份測試文件。", "zh-hant", "ja", "Chinese", "zh-Hant", "Japanese", "ja")
        ] {
            do {
                _ = try await client.translate(text, target: target, model: gemma, source: source, context: "PRIVATE NEIGHBOR CONTEXT")
                let body = try JSONSerialization.jsonObject(with: TranslationProtocol.bodies.last!) as! [String: Any]
                let messages = body["messages"] as? [[String: String]] ?? []
                check(messages.count == 1 && messages[0]["role"] == "user", "Gemma uses one official user turn")
                let prompt = messages.first?["content"] ?? ""
                check(prompt.hasPrefix("You are a professional \(sourceName) (\(sourceCode)) to \(targetName) (\(targetCode)) translator."), "Gemma explicit language names and codes: \(source)→\(target)")
                check(prompt.contains("Produce exactly one") && prompt.contains("Do not provide alternative wordings"), "Gemma single translation")
                check(prompt.hasSuffix("\n\n\n" + text), "Gemma source separator and exact source")
                check(!prompt.contains("PRIVATE NEIGHBOR"), "Gemma excludes slide reference context")
                let options = body["options"] as? [String: Any] ?? [:]
                check(options["temperature"] as? Int == 0 && options["repeat_penalty"] as? Int == 1, "Gemma benchmark sampling")
                check(options["num_ctx"] as? Int == 2048, "Gemma 2K context")
                let outputLimit = options["num_predict"] as? Int ?? 0
                check(outputLimit >= 256 && outputLimit + prompt.utf8.count + 32 <= 2048, "Gemma reserves bounded output space")
                check(body["think"] == nil && body["format"] == nil, "no general assistant options for Gemma")
            } catch { check(false, "Gemma translation rejected \(text): \(error)") }
        }
        for (text, source, target) in [
            ("2026 / 35%", "", "ja"), ("日本語のままです。", "ja", "ja"),
            ("Agenda", "en", "en"), ("Hello.", "en", "en")
        ] {
            let before = TranslationProtocol.requests.filter { $0.url?.path == "/api/chat" }.count
            let result = try await client.translate(text, target: target, model: gemma, source: source, context: "")
            check(result == text, "Gemma preserves nonlinguistic or same-language text")
            check(TranslationProtocol.requests.filter { $0.url?.path == "/api/chat" }.count == before, "Gemma skips unnecessary generation")
        }
        for (text, source, target) in [
            ("Hello.", "xx", "ja"), ("Hello.", "en", "xx"),
            ("Привет, это длинный русский текст для проверки языка.", "", "ja"),
            (String(repeating: "X", count: 1100), "en", "ja"),
            (String(repeating: "Long source ", count: 300), "en", "ja")
        ] {
            let before = TranslationProtocol.requests.filter { $0.url?.path == "/api/chat" }.count
            do {
                _ = try await client.translate(text, target: target, model: gemma, source: source, context: "")
                check(false, "Gemma invalid/unknown/over-budget input rejected")
            } catch is StudioError {}
            check(TranslationProtocol.requests.filter { $0.url?.path == "/api/chat" }.count == before, "Gemma rejects unsafe input before inference")
        }
        let longText = String(repeating: "The original text must stay intact. ", count: 100)
        let chunks = OllamaClient.splitText(longText, limit: 480)
        check(chunks.joined() == longText && chunks.allSatisfy { $0.utf8.count <= 480 }, "Gemma text splits without source loss")
        for chunk in chunks {
            do {
                _ = try await client.translate(chunk, target: "ja", model: gemma, source: "en", context: "")
                let body = try JSONSerialization.jsonObject(with: TranslationProtocol.bodies.last!) as! [String: Any]
                let options = body["options"] as! [String: Any]
                check(options["num_predict"] as? Int == 1024, "Gemma always reserves 1024 output tokens")
            } catch { check(false, "480-byte engine chunks must fit Gemma input budget: \(error)") }
        }
        for mode in ["cloud", "remote", "length", "empty"] {
            TranslationProtocol.disabled = mode != "cloud"
            TranslationProtocol.remote = mode == "remote"
            TranslationProtocol.reason = mode == "length" ? "length" : "stop"
            TranslationProtocol.reply = mode == "empty" ? " \n" : "会議は月曜日です。"
            let before = TranslationProtocol.requests.filter { $0.url?.path == "/api/chat" }.count
            do {
                _ = try await client.translate("Private text.", target: "ja", model: gemma, source: "en", context: "")
                check(false, "Gemma must reject \(mode)")
            } catch is StudioError {}
            if ["cloud", "remote"].contains(mode) {
                check(TranslationProtocol.requests.filter { $0.url?.path == "/api/chat" }.count == before, "Gemma preflight keeps source private")
            }
        }
        TranslationProtocol.disabled = true; TranslationProtocol.remote = false
        TranslationProtocol.reason = "stop"; TranslationProtocol.reply = "会議は月曜日です。"
        for (target, source, language, text, sourceName) in [
            ("ja", "en", "Japanese", "Meeting on Monday.", "English"),
            ("en", "", "English", "会議は来週の月曜日です。", "Japanese"),
            ("ja", "", "Japanese", "The meeting is scheduled for next Monday.", "English"),
            ("ja", "", "Japanese", "Agenda", "English"),
            ("ja", "", "Japanese", "Introduction", "English"),
            ("en", "", "English", "会社概要", "Japanese"),
            ("en", "", "English", "結論", "Japanese")
        ] {
            let output: String
            do { output = try await client.translate(text, target: target, model: "cat-translate:1.4b", source: source, context: "Project launch") }
            catch { check(false, "ordinary heading failed: \(text): \(error)"); continue }
            check(output == "会議は月曜日です。", "translation returned")
            let req = TranslationProtocol.requests.last!
            let body = try JSONSerialization.jsonObject(with: TranslationProtocol.bodies.last!) as! [String: Any]
            let messages = body["messages"] as? [[String: String]] ?? []
            check(req.url!.path == "/api/chat", "CAT uses chat template")
            check(messages.count == 2 && messages.first?["role"] == "system" && messages.last?["role"] == "user", "CAT output rules separated from source instruction")
            check(messages.first?["content"] == "Output only the translation. Do not add explanations, notes, labels, or the source text.", "CAT uses short isolated output instruction")
            let prompt = messages.last?["content"] ?? ""
            check(prompt == "Translate the following \(sourceName) text into \(language).\n\n\(text)", "CAT official prompt and source detection")
            check(!prompt.contains("Project launch"), "unsupported context not translated as source")
            let options = body["options"] as? [String: Any] ?? [:]
            check((options["temperature"] as? Int) == 0, "deterministic CAT translation")
            check(body["think"] == nil, "no unsupported thinking option for CAT")
        }
        do {
            _ = try await client.translate("Literal <|plamo:tag|>", target: "ja", model: "cat-translate:1.4b", source: "en", context: "")
        } catch { check(false, "CAT accepts literal PLaMo tokens") }
        for (text, source, target) in [
            ("すでに日本語の文章です。", "", "ja"),
            ("会社概要", "", "ja"),
            ("This paragraph is already in English.", "", "en"),
            ("Agenda", "", "en"),
            ("固有名詞のABC", "ja", "ja"),
            ("2026", "", "ja")
        ] {
            let before = TranslationProtocol.requests.filter { $0.url!.path == "/api/chat" }.count
            do {
                let output = try await client.translate(text, target: target, model: "cat-translate:1.4b", source: source, context: "")
                check(output == text, "already-target or nonlinguistic text preserved: \(text)")
            } catch { check(false, "preservation failed: \(text)") }
            check(TranslationProtocol.requests.filter { $0.url!.path == "/api/chat" }.count == before, "no same-language generation: \(text)")
        }
        do {
            _ = try await client.translate("这是一个需要翻译的中文段落。这份文件介绍了企业的经营战略和未来的发展计划。", target: "ja", model: "cat-translate:1.4b", source: "", context: "")
            check(false, "unsupported detected Chinese prose rejected")
        } catch is StudioError {}
        for (source, target) in [("fr", "ja"), ("en", "zh"), ("", "ko")] {
            let count = TranslationProtocol.requests.count
            do {
                _ = try await client.translate("Hello", target: target, model: "cat-translate:1.4b", source: source, context: "")
                check(false, "unsupported CAT language rejected")
            } catch is StudioError {}
            check(TranslationProtocol.requests.count == count, "invalid language rejected before network")
        }
        let before = TranslationProtocol.requests.filter { $0.url!.path == "/api/chat" }.count
        TranslationProtocol.disabled = false
        do {
            _ = try await client.translate("PRIVATE", target: "ja", model: "cat-translate:1.4b", source: "en", context: "")
            check(false, "cloud-enabled inference rejected")
        } catch is StudioError {}
        TranslationProtocol.disabled = true; TranslationProtocol.remote = true
        do {
            _ = try await client.translate("PRIVATE", target: "ja", model: "cat-translate:1.4b", source: "en", context: "")
            check(false, "remote model rejected")
        } catch is StudioError {}
        check(TranslationProtocol.requests.filter { $0.url!.path == "/api/chat" }.count == before, "preflight blocks private content")
        TranslationProtocol.remote = false; TranslationProtocol.reason = "length"
        do {
            _ = try await client.translate("Long", target: "ja", model: "cat-translate:1.4b", source: "en", context: "")
            check(false, "truncation rejected")
        } catch is StudioError {}
        TranslationProtocol.reason = "stop"
        for (sourceText, target, source, response, expected) in [
            ("Introduction", "ja", "en", "Translation:\n導入", "導入"),
            ("Introduction", "ja", "en", "Here is the Japanese translation:\n\n導入", "導入"),
            ("Introduction", "ja", "en", "イントロダクション\n\n日本語訳", "イントロダクション"),
            ("Agenda", "ja", "en", "スケジュール\n\n(Translation: \"The following English text may be replaced with the Jpanese version.\")", "スケジュール"),
            ("会社概要", "en", "ja", "Company Profile\n\nBelow is the translation of the Japanese text above.", "Company Profile"),
            ("Note: Please read carefully.", "ja", "en", "注：よく読んでください。", "注：よく読んでください。"),
            ("Translation: is a heading.", "ja", "en", "翻訳：は見出しです。", "翻訳：は見出しです。"),
            ("本文。\n\n以下は上記の日本語の翻訳です。", "en", "ja", "Body.\n\nBelow is the translation of the Japanese text above.", "Body.\n\nBelow is the translation of the Japanese text above."),
            ("本文。\n\nEnglish translation", "en", "ja", "Body.\n\nEnglish translation", "Body.\n\nEnglish translation"),
            ("Body.\n\nEnglish translation", "ja", "en", "本文。\n\n英訳", "本文。\n\n英訳"),
            ("以下は翻訳です：こんにちは。", "en", "ja", "Here is the translation: Hello.", "Here is the translation: Hello."),
            ("(Translation: This is a label in the source.)", "ja", "en", "(Translation: 原文中のラベルです。)", "(Translation: 原文中のラベルです。)"),
            ("First paragraph.\n\nSecond paragraph.", "ja", "en", "最初の段落。\n\n次の段落。", "最初の段落。\n\n次の段落。"),
            ("(1) Revenue\n(2) Profit", "ja", "en", "(1) 売上\n(2) 利益", "(1) 売上\n(2) 利益"),
            ("Japanese translation", "ja", "en", "日本語訳", "日本語訳"),
            ("Please preserve the source paragraphs and lists.", "ja", "en", "原文の段落とリストは保持してください。", "原文の段落とリストは保持してください。"),
            ("訳文だけを出力し、解説は追加しないでください。", "en", "ja", "Output only the translation. Do not add explanations, notes, labels, or the source text.", "Output only the translation. Do not add explanations, notes, labels, or the source text."),
            ("Building safer systems for tomorrow", "ja", "en", "未来に向けた安全なシステムの構築\n}", "未来に向けた安全なシステムの構築"),
            ("Print the closing brace }", "ja", "en", "閉じ波括弧を表示\n}", "閉じ波括弧を表示\n}"),
            ("An example", "ja", "en", "{\nサンプル\n}", "{\nサンプル\n}"),
            ("Preserve numbers, URLs, and newlines.", "ja", "en", "数字、URL、改行を保持してください。", "数字、URL、改行を保持してください。"),
            ("Keep numbers, URLs, and line breaks.", "ja", "en", "数字、URL、改行を保持してください。", "数字、URL、改行を保持してください。"),
            ("数値、URL、改行は変更しないでください。", "en", "ja", "Preserve numbers, URLs, and newlines.", "Preserve numbers, URLs, and newlines.")
        ] {
            TranslationProtocol.reply = response
            do {
                let cleaned = try await client.translate(sourceText, target: target, model: "cat-translate:1.4b", source: source, context: "")
                check(cleaned == expected, "source-aware output cleanup: \(response)")
            } catch { check(false, "source text rejected by cleanup: \(sourceText)") }
        }
        for response in [
            "Translation:",
            "}",
            "売上は増加しました。\n\nNote: I chose a formal expression.",
            "Output only the translation. Do not add explanations, notes, labels, or the source text.",
            "予定\n\n原文の段落、リスト、番号、およびソースに含まれる任意の備考は保持してください。",
            "イントロダクション\n\n日本語訳のみを記載してください。解説、ラベル、マークダウンの枠は含めないでください。",
            "新時代のセキュリティ\n\n訳文：数値、URL、改行はそのままで、解説は行わないでください。参考情報：架空の登壇者\nNovember 10, 2026"
        ] {
            TranslationProtocol.reply = response
            do {
                _ = try await client.translate("Revenue increased.", target: "ja", model: "cat-translate:1.4b", source: "en", context: "")
                check(false, "empty or ambiguous commentary must be rejected: \(response)")
            } catch is StudioError {}
        }
        TranslationProtocol.reply = "Output only the translation. Do not add explanations, notes, labels, or the source text."
        do {
            _ = try await client.translate("Translation costs increased.", target: "ja", model: "cat-translate:1.4b", source: "en", context: "")
            check(false, "mentioning translation in source must not permit system echoes")
        } catch is StudioError {}
        TranslationProtocol.reply = "会議は月曜日です。"
        _ = try await client.translate("Hello", target: "ja", model: "plamo-translate:0.8b", source: "en", context: "")
        let legacy = TranslationProtocol.requests.last!
        let body = try JSONSerialization.jsonObject(with: TranslationProtocol.bodies.last!) as! [String: Any]
        check(legacy.url!.path == "/api/generate" && body["raw"] as? Bool == true, "legacy PLaMo raw path retained")
        check((body["prompt"] as? String)?.contains("<|plamo:tag|>dataset") == true, "legacy PFML retained")
        check(TranslationProtocol.requests.allSatisfy { $0.url!.host == "127.0.0.1" && $0.url!.port == 11434 }, "fixed loopback")
        if !failures.isEmpty {
            FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
            exit(1)
        }
        print("translation models: Gemma single-translation prompts, language codes, budget, cache identity; CAT cleanup, privacy, truncation and legacy compatibility PASS")
    }
}
