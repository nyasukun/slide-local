import AppKit
import SwiftUI

// A real AppKit/SwiftUI rendering smoke check, with synthetic content and no
// connection to the user's Ollama service or app storage. Not a VoiceOver test.
@main struct NativeLayoutTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = try ProjectStore(root: root), engine = try NativeEngine(store: store, inference: UXInference())
        let p = try await engine.importFile(URL(fileURLWithPath: CommandLine.arguments[2]))
        let studio = StudioModel(engine: engine)
        try await studio.selectProject(p.id)
        studio.projects = await engine.projects()
        await studio.refreshModels()
        studio.chatModel = "qwen3.5:4b"
        studio.models.append(LocalModel(name: studio.chatModel, size: 1))
        for width in [1100, 1450] {
            for chat in [false, true] {
                studio.showChat = chat
                let host = NSHostingView(rootView: StudioView().environmentObject(studio).preferredColorScheme(.light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 760)
                host.layoutSubtreeIfNeeded()
                guard host.bounds.width == CGFloat(width), host.bounds.height == 760 else {
                    throw StudioError("native rendering bounds changed: \(host.bounds)")
                }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw StudioError("native bitmap unavailable") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]), data.count > 1000 else { throw StudioError("native rendering empty") }
                try data.write(to: root.appendingPathComponent("layout-\(width)-chat-\(chat).png"))
                print("native SwiftUI rendered \(width)×760 chat=\(chat) PASS (visual clipping checked separately)")
                window.orderOut(nil)
            }
        }
        let request = TranslationRequest(ids: [p.id], options: studio.currentOptions, assessments: try await engine.assessTranslation([p.id], options: studio.currentOptions))
        let confirmation = NSHostingView(rootView: TranslationConfirmationSheet(request: request).environmentObject(studio).preferredColorScheme(.light).background(Color.white))
        let confirmationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        confirmationWindow.contentView = confirmation
        confirmation.frame = NSRect(x: 0, y: 0, width: 600, height: 560); confirmation.layoutSubtreeIfNeeded()
        guard let bitmap = confirmation.bitmapImageRepForCachingDisplay(in: confirmation.bounds) else { throw StudioError("confirmation rendering unavailable") }
        confirmation.cacheDisplay(in: confirmation.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: root.appendingPathComponent("confirmation.png")) }
        confirmationWindow.orderOut(nil)
        print("native SwiftUI confirmation rendered (interaction/VoiceOver not automated)")
    }
}
