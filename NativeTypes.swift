import Foundation

struct StudioError: LocalizedError { var message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
struct Slide: Codable, Identifiable, Sendable { var number: Int; var path: String; var units: [String]; var images: Int; var id: Int { number } }
struct TextUnit: Codable, Identifiable, Sendable {
    var id: String; var part: String; var index: Int; var kind: String
    var source: String; var translation = ""; var slides: [Int]; var status = "pending"; var error = ""; var rich = false
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
    var source = ""; var target = "ja"; var model = "plamo-translate:0.8b"
    var completed = 0; var total = 0; var fit = true; var include_notes: Bool?
    var slides: [Slide]; var units: [TextUnit]; var chats: [ChatRecord] = []
    var preview_state = "idle"; var preview_version = "source"; var preview_error = ""; var preview_stamp: Double?
}
struct ProjectItem: Codable, Identifiable, Sendable { var id: String; var filename: String; var slide_count: Int; var state: String }
struct LocalModel: Codable, Identifiable, Sendable { var name: String; var size: Double; var digest: String?; var id: String { name } }
struct ChatBubble: Identifiable { var id = UUID(); var role: String; var text: String; var refs: [Int] = []; var failed = false }
struct QueueOptions: Codable, Sendable { var target: String; var source: String; var model: String; var notes: Bool; var fit: Bool }
struct QueueItem: Codable, Identifiable, Sendable {
    var id: String; var project_id: String; var filename: String; var status: String; var message: String
    var options: QueueOptions; var completed: Int?; var total: Int?
    var created: Double?; var started: Double?; var finished: Double?; var cancel_requested: Bool?
}
struct QueueState: Codable, Sendable { var paused: Bool; var items: [QueueItem] }
func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
