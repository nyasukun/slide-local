import Foundation

@main struct NativeCoreTests {
    static func main() async throws {
        let args = CommandLine.arguments
        switch args[1] {
        case "inspect":
            let inventory = try PPTX.inspect(URL(fileURLWithPath: args[2]))
            FileHandle.standardOutput.write(try JSONEncoder().encode(inventory))
        case "export":
            let units = try JSONDecoder().decode([TextUnit].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
            try PPTX.export(source: URL(fileURLWithPath: args[2]), units: units, fit: true, destination: URL(fileURLWithPath: args[4]))
        case "preview-copy":
            try PPTX.preparePreview(source: URL(fileURLWithPath: args[2]), destination: URL(fileURLWithPath: args[3]))
        case "reject":
            do { _ = try PPTX.inspect(URL(fileURLWithPath: args[2])); throw NSError(domain: "test", code: 1) }
            catch is StudioError { print("invalid PPTX rejected without trapping") }
        case "cache-key":
            let key = try ProjectStore.cacheKey(digest: args[2], target: args[3], source: args[4], context: args[5], text: args[6])
            FileHandle.standardOutput.write(Data(key.utf8))
        case "lock":
            let store = try ProjectStore(root: URL(fileURLWithPath: args[2]))
            try withExtendedLifetime(store) {
                do { _ = try ProjectStore(root: store.root); throw StudioError("double writer allowed") }
                catch let error as StudioError { precondition(error.message != "double writer allowed") }
            }
            print("native data-root lock PASS")
        case "store":
            let legacy = URL(fileURLWithPath: args[2]), target = URL(fileURLWithPath: args[3])
            try ProjectStore.migrate(legacy: legacy, destination: target)
            try ProjectStore.migrate(legacy: legacy, destination: target)
            let store = try ProjectStore(root: target)
            let projects = try store.list()
            precondition(!projects.isEmpty)
            for project in projects { _ = try store.load(project.id) }
            try store.cachePut("native-test", value: "日本語キャッシュ")
            let inherited = try store.cacheGet("legacy-key"); if args.count > 4 { precondition(inherited == args[4]) }
            let cached = try store.cacheGet("native-test"); precondition(cached == "日本語キャッシュ")
            precondition(OllamaClient.isLocalModel(["name": "qwen3.5:4b"]))
            precondition(!OllamaClient.isLocalModel(["name": "remote:cloud"]))
            precondition(!OllamaClient.isLocalModel(["name": "plain", "remote_host": "example.com"]))
            FileHandle.standardOutput.write(try JSONEncoder().encode(projects))
        default: throw StudioError("Unknown check")
        }
    }
}
