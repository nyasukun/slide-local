import Foundation
import UniformTypeIdentifiers

/// Start the file-URL request inside the synchronous drop callback. Only its
/// result is awaited later; no provider access is deferred beyond that callback.
enum FileURLDropLoader {
    static func begin(_ provider: NSItemProvider, timeout: TimeInterval = 15) -> FileURLDropLoad {
        let request = FileURLDropLoad(provider: provider)
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            request.finish(.failure(StudioError("FinderにあるPowerPointファイル（.pptx）をドロップしてください。")))
            return request
        }
        // This API starts an asynchronous data request; it must be called before
        // onDrop returns. Never request generic object/file-data conversion.
        let progress = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
            guard error == nil, let data, let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.isFileURL, url.pathExtension.lowercased() == "pptx" else {
                request.finish(.failure(StudioError("ファイルの場所を取得できませんでした。Finderの.pptxを使うか、「PowerPointを開く…」から選んでください。")))
                return
            }
            request.finish(.success(url))
        }
        request.attach(progress)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0.01, timeout)) {
            request.finish(.failure(StudioError("ファイルの場所の取得に時間がかかっています。ドロップを中止しました。「PowerPointを開く…」から選んでください。")), cancel: true)
        }
        return request
    }
    static func load(_ provider: NSItemProvider, timeout: TimeInterval = 15) async throws -> URL {
        try await begin(provider, timeout: timeout).value()
    }
}

final class FileURLDropLoad: @unchecked Sendable {
    // The provider is retained for the already-started request, never accessed
    // after begin. All completion/deadline/consumer state is protected by lock.
    private let lock = NSLock()
    private var provider: NSItemProvider?
    private var result: Result<URL, Error>?
    private var waiters: [CheckedContinuation<URL, Error>] = []
    private var progress: Progress?
    private var cancelWhenAttached = false
    init(provider: NSItemProvider) { self.provider = provider }
    func value() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    func attach(_ progress: Progress) {
        lock.lock()
        let shouldCancel = cancelWhenAttached
        if result == nil { self.progress = progress }
        lock.unlock()
        if shouldCancel { progress.cancel() }
    }
    func finish(_ result: Result<URL, Error>, cancel: Bool = false) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let progress = self.progress
        let retainedProvider = provider
        provider = nil
        let waiters = self.waiters
        self.waiters = []; self.progress = nil; cancelWhenAttached = cancel
        lock.unlock()
        if cancel { progress?.cancel() }
        withExtendedLifetime(retainedProvider) { for waiter in waiters { waiter.resume(with: result) } }
    }
}
