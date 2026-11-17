import Foundation
import AppKit

@main struct NativePreviewSmoke {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2 && args[1] == "policy" { print(NativePreviewPolicy.sandbox); return }
        let source = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
        try NativePreview.render(source: source, output: output)
        let image = try NativePreview.image(folder: output, translated: false, slide: 1)
        guard let bitmap = NSImage(contentsOf: image), bitmap.size.width > 0 else { throw StudioError("dummy preview is missing") }
        print("benign offline preview: PDF and PNG generated under renderer sandbox PASS")
    }
}
