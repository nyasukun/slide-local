import Foundation
import CryptoKit

func atomicSave(_ source: URL, to destination: URL, overwrite: Bool = true) throws {
    let fm = FileManager.default
    let staged = destination.deletingLastPathComponent().appendingPathComponent(".SlideLocal-save-" + newID())
    defer { try? fm.removeItem(at: staged) }
    try fm.copyItem(at: source, to: staged)
    if !overwrite {
        // Hard-linking a staged file on the same filesystem installs it atomically
        // only if the destination does not exist, including cross-process races.
        guard link(staged.path, destination.path) == 0 else {
            if errno == EEXIST { throw CocoaError(.fileWriteFileExists) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    else if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: staged) }
    else { try fm.moveItem(at: staged, to: destination) }
}

final class ProjectStore {
    let root: URL
    private var database: OpaquePointer?
    private var lockFD: Int32 = -1
    private(set) var recoveryMessages: [String] = []
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }()
    init(root: URL, locking: Bool = true) throws {
        self.root = root
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if locking {
            lockFD = open(root.appendingPathComponent("native.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { if lockFD >= 0 { close(lockFD); lockFD = -1 }; throw StudioError("この保存先は別のSlide Localで使用中です。既存のアプリを開いてください。") }
        }
        guard sqlite3_open_v2(root.appendingPathComponent("cache.sqlite").path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw StudioError("翻訳キャッシュを開けません。") }
        sqlite3_busy_timeout(database, 5000)
        try execute("CREATE TABLE IF NOT EXISTS translations (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }
    deinit { if let database { sqlite3_close(database) }; if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
    static func defaultRoot() throws -> URL { try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Slide Local", isDirectory: true) }
    static func migrate(legacy: URL, destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        guard fm.fileExists(atPath: legacy.path) else { return }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".SlideLocal-migration-" + newID())
        defer { try? fm.removeItem(at: stage) }
        // Copy first. Never rename or edit the old .data tree. Commit only after hashes agree.
        try fm.copyItem(at: legacy, to: stage)
        let before = try manifest(legacy), after = try manifest(stage)
        guard before == after else { let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted(); throw StudioError("データ移行の検証に失敗しました。元データは変更していません。差分: \(changed.prefix(4))") }
        let candidates = try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil }
        for folder in candidates {
            let path = folder.appendingPathComponent("project.json")
            if fm.fileExists(atPath: path.path) { _ = try JSONDecoder().decode(Project.self, from: Data(contentsOf: path)) }
        }
        let receipt: [String: Any] = ["schema": 2, "source": legacy.path, "migrated": Date().timeIntervalSince1970, "projects": candidates.count, "files": before.count]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: stage.appendingPathComponent("migration.json"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
        try fm.moveItem(at: stage, to: destination)
    }
    static func manifest(_ root: URL) throws -> [String: String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root.path) else { throw StudioError("保存データを検証できません。") }
        var result: [String: String] = [:]
        for case let relative as String in enumerator {
            let file = root.appendingPathComponent(relative)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw StudioError("保存先にシンボリックリンクが含まれています。") }
            guard values.isRegularFile == true else { continue }
            var hasher = SHA256(); let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1048576), !chunk.isEmpty { hasher.update(data: chunk) }
            result[relative] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    func folder(_ id: String) throws -> URL {
        guard id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { throw StudioError("資料の識別子が正しくありません。") }
        return root.appendingPathComponent(id, isDirectory: true)
    }
    func load(_ id: String) throws -> Project {
        let path = try folder(id).appendingPathComponent("project.json")
        do { let p = try decoder.decode(Project.self, from: Data(contentsOf: path)); guard p.id == id else { throw StudioError("識別子が一致しません。") }; guard Set(p.units.map { $0.id }).count == p.units.count else { throw StudioError("段落IDが重複しています。") }; return p }
        catch { throw StudioError("資料の保存データを読めません（元データを保持しています）: \(id) — \(error.localizedDescription)") }
    }
    func save(_ project: Project) throws {
        let folder = try folder(project.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(project).write(to: folder.appendingPathComponent("project.json"), options: [.atomic])
    }
    func list() throws -> [ProjectItem] {
        var values: [(Double, ProjectItem)] = []
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where folder.lastPathComponent.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil {
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path) {
                let recovery = root.appendingPathComponent("incomplete-imports", isDirectory: true)
                try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
                var target = recovery.appendingPathComponent(folder.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) { target = recovery.appendingPathComponent(folder.lastPathComponent + "-" + newID()) }
                try FileManager.default.moveItem(at: folder, to: target)
                recoveryMessages.append("中断された読み込みデータを保持しました: " + target.path)
                continue
            }
            let p = try load(folder.lastPathComponent)
            values.append((p.created, ProjectItem(id: p.id, filename: p.filename, slide_count: p.slide_count, state: p.state)))
        }
        return values.sorted { $0.0 > $1.0 }.map { $0.1 }
    }
    func loadQueue() throws -> QueueState {
        let file = root.appendingPathComponent("queue.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return QueueState(paused: false, items: []) }
        do { return try decoder.decode(QueueState.self, from: Data(contentsOf: file)) }
        catch { throw StudioError("翻訳キューの保存データを読めません。元ファイルは保持しています。") }
    }
    func saveQueue(_ queue: QueueState) throws { try encoder.encode(queue).write(to: root.appendingPathComponent("queue.json"), options: [.atomic]) }
    private func execute(_ sql: String) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StudioError("翻訳キャッシュを更新できません。") } }
    func cacheGet(_ key: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM translations WHERE key=?", -1, &statement, nil) == SQLITE_OK else { throw StudioError("キャッシュ検索を開始できません。") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw StudioError("キャッシュを読み出せません。") }
        return String(cString: value)
    }
    func cachePut(_ key: String, value: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO translations VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else { throw StudioError("キャッシュ保存を開始できません。") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient); sqlite3_bind_text(statement, 2, value, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StudioError("キャッシュを保存できません。") }
    }
    static func cacheKey(digest: String, target: String, source: String, context: String, text: String) throws -> String {
        // Match Python json.dumps([...], ensure_ascii=False), including its comma spaces.
        let values = try [digest, target, source, context, text].map { String(data: try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)! }
        let input = "[" + values.joined(separator: ", ") + "]"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
