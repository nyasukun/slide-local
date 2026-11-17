import Foundation

// No socket or live Ollama: URLProtocol records only dummy requests in this process.
final class PrivacyProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var cloudDisabled = false
    static var remote = false
    static var contentRequests = 0
    static var destinations: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.destinations.append(request.url!.absoluteString)
        let path = request.url!.path
        let value: [String: Any]
        if path == "/api/status" { value = ["cloud": ["disabled": Self.cloudDisabled]] }
        else if path == "/api/tags" { value = ["models": [["name": "dummy:latest", "size": 1, "digest": "dummy", "remote_host": Self.remote ? "https://invalid.example" : ""]]] }
        else { Self.contentRequests += 1; value = ["response": "dummy translation", "done": true] }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
@main struct NativePrivacyTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacyProtocol.self]
        let client = OllamaClient(configuration: configuration)
        do {
            _ = try await client.translate("DUMMY_DOCUMENT_TEXT", target: "ja", model: "dummy:latest", source: "", context: "")
            throw NSError(domain: "test.cloud.content_sent", code: 1)
        } catch is StudioError { }
        precondition(PrivacyProtocol.contentRequests == 0)
        do {
            for try await _ in client.chat(model: "dummy:latest", messages: [["role": "user", "content": "DUMMY_QUESTION"]]) { }
            throw NSError(domain: "test.chat.cloud.content_sent", code: 1)
        } catch is StudioError { }
        precondition(PrivacyProtocol.contentRequests == 0)
        PrivacyProtocol.cloudDisabled = true; PrivacyProtocol.remote = true
        do {
            _ = try await client.translate("DUMMY_DOCUMENT_TEXT", target: "ja", model: "dummy:latest", source: "", context: "")
            throw NSError(domain: "test.remote.content_sent", code: 1)
        } catch is StudioError { }
        precondition(PrivacyProtocol.contentRequests == 0)
        PrivacyProtocol.remote = false
        _ = try await client.translate("DUMMY_DOCUMENT_TEXT", target: "ja", model: "dummy:latest", source: "", context: "")
        precondition(PrivacyProtocol.contentRequests == 1)
        precondition(PrivacyProtocol.destinations.allSatisfy { URL(string: $0)?.host == "127.0.0.1" && URL(string: $0)?.port == 11434 })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SlideLocal-privacy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("render/result"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let render = root.appendingPathComponent("render"), leaf = render.appendingPathComponent("result/input.pdf"), destination = root.appendingPathComponent("promoted.pdf")
        let dummy = root.appendingPathComponent("dummy-private.pdf")
        try Data("%PDF-DUMMY-NO-USER-DATA".utf8).write(to: dummy)
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: dummy)
        do { try NativePreviewPolicy.promotePDF(root: render, destination: destination); throw NSError(domain: "test.symlink_promoted", code: 1) }
        catch is StudioError { }
        precondition(!FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.removeItem(at: leaf)
        try FileManager.default.linkItem(at: dummy, to: leaf)
        do { try NativePreviewPolicy.promotePDF(root: render, destination: destination); throw NSError(domain: "test.hardlink_promoted", code: 1) }
        catch is StudioError { }
        try FileManager.default.removeItem(at: leaf)
        try Data("%PDF-DUMMY-OUTPUT".utf8).write(to: leaf)
        try NativePreviewPolicy.promotePDF(root: render, destination: destination)
        let copied = try Data(contentsOf: destination); precondition(copied == Data("%PDF-DUMMY-OUTPUT".utf8))
        print("privacy: cloud/remote preflight fails before dummy content, only fixed loopback URLs PASS")
    }
}
