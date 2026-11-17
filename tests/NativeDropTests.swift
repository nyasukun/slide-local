import Foundation

final class DropCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Data?, Error?) -> Void)?
    func set(_ value: @escaping (Data?, Error?) -> Void) { lock.lock(); callback = value; lock.unlock() }
    func finish(_ data: Data) { lock.lock(); let value = callback; lock.unlock(); value?(data, nil) }
}
final class PreviewCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func record() { lock.lock(); calls += 1; lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
}
final class ScopedDropProvider: NSItemProvider, @unchecked Sendable {
    var scopeOpen = true, startedInScope = false
    private let bytes: Data
    init(url: URL) { bytes = Data(url.absoluteString.utf8); super.init() }
    override func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool { typeIdentifier == "public.file-url" }
    override func loadDataRepresentation(forTypeIdentifier typeIdentifier: String, completionHandler: @escaping @Sendable (Data?, Error?) -> Void) -> Progress {
        startedInScope = scopeOpen
        completionHandler(scopeOpen ? bytes : nil, scopeOpen ? nil : StudioError("drop scope expired"))
        return Progress(totalUnitCount: 1)
    }
}

@main struct NativeDropTests {
    @MainActor static func check(_ value: Bool, _ message: String) throws { if !value { throw StudioError(message) } }
    @MainActor static func until(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            if Date() > deadline { throw StudioError("drop did not finish") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), file = URL(fileURLWithPath: CommandLine.arguments[2])
        let store = try ProjectStore(root: root), renders = PreviewCalls()
        let engine = try NativeEngine(store: store, inference: UXInference(), previewRenderer: { _, _ in renders.record() })
        let studio = StudioModel(engine: engine)
        let provider = ScopedDropProvider(url: file)
        studio.dropTarget = true
        studio.preview = true
        try check(studio.handleDrop([provider]), "Finder-style file URL was rejected")
        provider.scopeOpen = false
        try check(provider.startedInScope, "file URL request started after the drop callback returned")
        try check(studio.working && studio.actionBusy && !studio.dropTarget, "drop URL resolution has no progress/lock or leaves drag overlay stuck")
        try await until { !studio.working && !studio.actionBusy }
        try check(studio.project != nil && studio.error == nil, "raw file-URL drop did not import")
        try check(!studio.preview && !studio.translatedPreview && studio.previewImage == nil, "new import reused image-preview mode without user request")
        try check(studio.project?.preview_state == "idle", "import started preview rendering")
        try check((await engine.queueSnapshot()).items.isEmpty, "drop automatically started translation")
        try check(renders.count() == 0, "drop launched LibreOffice renderer")
        let unicodeFile = root.appendingPathComponent("資料 テスト #%.pptx")
        try FileManager.default.copyItem(at: file, to: unicodeFile)
        let nativeProvider = NSItemProvider(object: unicodeFile as NSURL)
        let nativeURL = try await FileURLDropLoader.begin(nativeProvider, timeout: 2).value()
        try check(nativeURL == unicodeFile, "native file-URL provider lost spaces or non-ASCII filename")
        let invalid = NSItemProvider()
        invalid.registerDataRepresentation(forTypeIdentifier: "public.file-url", visibility: .all) { completion in
            completion(Data("https://example.invalid/file.pptx".utf8), nil); return nil
        }
        studio.error = "以前の別エラー"
        try check(studio.handleDrop([invalid]), "file-URL provider not accepted for validation")
        try await until { !studio.working && !studio.actionBusy }
        try check(studio.error != nil && !studio.dropTarget, "invalid drop failed silently or retained overlay")
        try check(studio.error?.contains("以前の別エラー") == false, "drop feedback mixed in an unrelated prior error")
        let stalled = NSItemProvider(), callbacks = DropCallbacks()
        let progress = Progress(totalUnitCount: 1)
        stalled.registerDataRepresentation(forTypeIdentifier: "public.file-url", visibility: .all) { completion in
            callbacks.set(completion); return progress
        }
        do {
            _ = try await FileURLDropLoader.load(stalled, timeout: 0.03)
            throw StudioError("stalled provider never timed out")
        } catch let error as StudioError {
            try check(error.message != "stalled provider never timed out", error.message)
        }
        try check(progress.isCancelled, "stalled drop request not cancelled")
        callbacks.finish(Data(file.absoluteString.utf8)) // Late callback must not resume twice.
        let batchStart = Date()
        let pending = (0..<4).map { _ -> FileURLDropLoad in
            let item = NSItemProvider()
            item.registerDataRepresentation(forTypeIdentifier: "public.file-url", visibility: .all) { _ in Progress(totalUnitCount: 1) }
            return FileURLDropLoader.begin(item, timeout: 0.05)
        }
        let valid = FileURLDropLoader.begin(ScopedDropProvider(url: file), timeout: 0.05)
        for load in pending {
            do {
                _ = try await load.value()
                throw StudioError("stalled load unexpectedly succeeded")
            } catch let error as StudioError {
                try check(error.message.contains("時間がかかっています"), "stalled load did not fail by timeout: " + error.message)
            }
        }
        let resolved = try await valid.value()
        try check(resolved == file && Date().timeIntervalSince(batchStart) < 0.18, "drop deadlines accumulated sequentially")
        let preserved = studio.project!
        studio.error = nil
        studio.requestTranslation(ids: [preserved.id], options: studio.currentOptions)
        try await until { !studio.actionBusy }
        let deadline = Date().addingTimeInterval(10)
        while (await engine.queueSnapshot()).items.contains(where: { ["queued", "running"].contains($0.status) }) {
            if Date() > deadline { throw StudioError("translation timeout") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await studio.refreshCurrent()
        let exported = try await engine.export(preserved.id)
        try check(renders.count() == 0, "translation/export launched LibreOffice renderer")
        try FileManager.default.removeItem(at: exported)
        studio.preview = true; studio.translatedPreview = false
        studio.renderPreview()
        try await until { renders.count() == 1 && !studio.actionBusy }
        try check(renders.count() == 1, "explicit preview did not invoke renderer exactly once")
        let other = try await engine.importFile(file)
        try await studio.selectProject(other.id)
        try check(!studio.preview && !studio.translatedPreview && renders.count() == 1, "switching projects reused or regenerated a preview")
        print("drop: raw Finder URLs, immediate progress, import without preview/translation, invalid URL feedback PASS")
    }
}
