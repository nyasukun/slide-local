import Foundation

struct StudioError: LocalizedError { var message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
struct Slide: Codable, Identifiable, Sendable { var number: Int; var path: String; var units: [String]; var images: Int; var id: Int { number } }
struct TextUnit: Codable, Identifiable, Sendable {
    var id: String; var part: String; var index: Int; var kind: String
    var source: String; var translation = ""; var slides: [Int]; var status = "pending"; var error = ""; var rich = false
    var regenerate_pending: Bool?
}
struct DeckInventory: Codable { var slides: [Slide]; var units: [TextUnit]; var slide_count: Int; var image_count: Int }
struct ChatRecord: Codable, Identifiable, Sendable {
    var question: String; var answer: String; var refs: [Int]; var model: String
    var id: String { question + answer }
}
struct Project: Codable, Identifiable, Sendable {
    var id: String; var filename: String; var created: Double
    var slide_count: Int; var image_count: Int
    var state = "ready"; var message = "翻訳する言語を選んでください。"
    var source = "en"; var target = "ja"; var model = LocalModel.defaultTranslation
    var completed = 0; var total = 0; var fit = true; var include_notes: Bool?
    var slides: [Slide]; var units: [TextUnit]; var chats: [ChatRecord] = []
    var preview_state = "idle"; var preview_version = "source"; var preview_error = ""; var preview_stamp: Double?
    var translation_request_id: String?
    var source_preview: PreviewRecord?
    var translated_preview: PreviewRecord?
    var chat_generation: String?
}
struct PreviewRecord: Codable, Sendable {
    var state: String
    var fingerprint: String?
    var stamp: Double?
    var error: String?
}
struct ProjectItem: Codable, Identifiable, Sendable { var id: String; var filename: String; var slide_count: Int; var state: String }
struct LocalModel: Codable, Identifiable, Sendable { var name: String; var size: Double; var digest: String?; var id: String { name } }
extension LocalModel {
    static let defaultTranslation = "translategemma:12b-it-q4_K_M"
    static func isCATTranslation(_ name: String) -> Bool { name.lowercased().contains("cat-translate") }
    static func isTranslateGemma(_ name: String) -> Bool { name.lowercased().contains("translategemma") }
    static func isTranslationOnly(_ name: String) -> Bool { isCATTranslation(name) || isTranslateGemma(name) || name.lowercased().contains("plamo") }
    // UI language keys and the model's documented language-name/code prompt fields.
    static let gemmaLanguages: [String: (name: String, code: String)] = [
        "ja": ("Japanese", "ja"), "en": ("English", "en"),
        "zh-hans": ("Chinese", "zh-Hans"), "zh-hant": ("Chinese", "zh-Hant"),
        "ko": ("Korean", "ko"), "fr": ("French", "fr"),
        "de": ("German", "de"), "es": ("Spanish", "es")
    ]
    static func translationCacheDigest(_ digest: String, model: String) -> String {
        if isTranslateGemma(model) { return digest + ":translategemma-single-v1" }
        return isCATTranslation(model) ? digest + ":cat-output-v4" : digest
    }
    static func translationLanguageError(model: String, source: String, target: String) -> String? {
        if isTranslateGemma(model) {
            return gemmaLanguages[target] != nil && (source.isEmpty || gemmaLanguages[source] != nil)
                ? nil : "TranslateGemmaで使える原文・翻訳先の言語を選び直してください。"
        }
        guard isCATTranslation(model) else { return nil }
        return ["ja", "en"].contains(target) && ["", "ja", "en"].contains(source) ? nil : "CAT-Translateは日本語と英語にのみ対応しています。原文・翻訳先の言語を選び直してください。"
    }
}
struct ChatBubble: Identifiable { var id = UUID(); var role: String; var text: String; var refs: [Int] = []; var failed = false }
struct QueueOptions: Codable, Sendable, Equatable { var target: String; var source: String; var model: String; var notes: Bool; var fit: Bool }
struct QueueItem: Codable, Identifiable, Sendable {
    var id: String; var project_id: String; var filename: String; var status: String; var message: String
    var options: QueueOptions; var completed: Int?; var total: Int?
    var created: Double?; var started: Double?; var finished: Double?; var cancel_requested: Bool?
    var approved_fingerprint: String?
    var regenerate: Bool?
}
struct QueueState: Codable, Sendable { var paused: Bool; var items: [QueueItem] }
func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
