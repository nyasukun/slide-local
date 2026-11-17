import Foundation

private let drawingNS = "http://schemas.openxmlformats.org/drawingml/2006/main"
private let presentationNS = "http://schemas.openxmlformats.org/presentationml/2006/main"
private let chartNS = "http://schemas.openxmlformats.org/drawingml/2006/chart"
private let spreadsheetNS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
private let relationshipNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
private func document(_ data: Data) throws -> XMLDocument {
    // OOXML never requires a DTD. Reject declarations before parsing (also UTF-16/32).
    let probe = String(decoding: data.filter { $0 != 0 }, as: UTF8.self).lowercased()
    guard !probe.contains("<!doctype"), !probe.contains("<!entity") else { throw StudioError("DTDを含むXMLには対応していません。") }
    return try XMLDocument(data: data, options: XMLNode.Options.nodePreserveAll.subtracting(.nodePreserveWhitespace).union([.nodePromoteSignificantWhitespace, .nodeLoadExternalEntitiesNever]))
}
private func descendants(_ node: XMLNode, _ name: String, _ ns: String) throws -> [XMLElement] {
    var stack = Array((node.children ?? []).reversed()), found: [XMLElement] = []
    while let item = stack.popLast() {
        if let element = item as? XMLElement, element.localName == name, element.uri == ns { found.append(element) }
        stack.append(contentsOf: (item.children ?? []).reversed())
    }
    return found
}
private func direct(_ node: XMLNode, _ name: String, _ ns: String) -> [XMLElement] {
    (node.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name && $0.uri == ns }
}
private func attribute(_ node: XMLElement, _ name: String, _ value: String, uri: String? = nil) {
    if let existing = node.attribute(forName: name) { existing.stringValue = value; return }
    let a = XMLNode.attribute(withName: name, stringValue: value) as! XMLNode
    if let uri { a.uri = uri }
    node.addAttribute(a)
}
private struct Relationship { var id: String; var kind: String; var target: String }
private func relationships(_ zip: ZipArchive, _ part: String) throws -> [Relationship] {
    let directory = (part as NSString).deletingLastPathComponent
    let file = (part as NSString).lastPathComponent
    let rels = directory + "/_rels/" + file + ".rels"
    guard zip.contains(rels) else { return [] }
    let tree = try document(zip.read(rels))
    return try (tree.rootElement()?.children ?? []).compactMap { node in
        guard let r = node as? XMLElement, r.attribute(forName: "TargetMode")?.stringValue != "External", let target = r.attribute(forName: "Target")?.stringValue else { return nil }
        let decoded = target.removingPercentEncoding ?? target
        let path = ((decoded.hasPrefix("/") ? decoded : "/" + directory + "/" + decoded) as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.split(separator: "/").contains(".."), !path.contains("\\"), !path.contains(":") else { throw StudioError("PPTXの参照先が不正です。") }
        return Relationship(id: r.attribute(forName: "Id")?.stringValue ?? "", kind: (r.attribute(forName: "Type")?.stringValue ?? "").components(separatedBy: "/").last ?? "", target: path)
    }
}

struct PPTX {
    static func preparePreview(source: URL, destination: URL) throws {
        let archive = try ZipArchive(source)
        var replacements: [String: Data] = [:]
        for entry in archive.entries where entry.name.hasSuffix(".rels") {
            let tree = try document(archive.read(entry.name))
            var changed = false
            for case let relationship as XMLElement in tree.rootElement()?.children ?? [] {
                if relationship.attribute(forName: "TargetMode")?.stringValue?.lowercased() == "external" {
                    relationship.detach(); changed = true
                }
            }
            if changed { replacements[entry.name] = tree.xmlData(options: [.nodePreserveAll]) }
        }
        try archive.rewrite(destination: destination, replacements: replacements)
    }
    static func inspect(_ url: URL) throws -> DeckInventory {
        let zip = try ZipArchive(url)
        guard zip.contains("ppt/presentation.xml") else { throw StudioError("PowerPoint形式のファイルではありません。") }
        let rels = try relationships(zip, "ppt/presentation.xml")
        var paths: [String: String] = [:]
        for rel in rels where rel.kind == "slide" {
            guard !rel.id.isEmpty, paths.updateValue(rel.target, forKey: rel.id) == nil else { throw StudioError("スライド参照のIDが重複または欠落しています。") }
        }
        let presentation = try document(zip.read("ppt/presentation.xml"))
        let slideIDs = try descendants(presentation, "sldId", presentationNS)
        var units: [TextUnit] = [], slides: [Slide] = [], seen: [String: [Int]] = [:]
        for (index, id) in slideIDs.enumerated() {
            try Task.checkCancellation()
            guard let rid = id.attribute(forLocalName: "id", uri: relationshipNS)?.stringValue, let path = paths[rid] else { throw StudioError("スライドの参照が見つかりません。") }
            let number = index + 1
            let root = try document(zip.read(path))
            var slide = Slide(number: number, path: path, units: [], images: try descendants(root, "pic", presentationNS).count)
            var parts: [(String, String)] = [(path, "slide")]
            for rel in try relationships(zip, path) where ["chart", "diagramData", "diagramDrawing", "notesSlide"].contains(rel.kind) {
                parts.append((rel.target, rel.kind == "notesSlide" ? "notes" : rel.kind))
                if rel.kind == "diagramData" {
                    for child in try relationships(zip, rel.target) where child.kind == "diagramDrawing" { parts.append((child.target, child.kind)) }
                }
            }
            for (part, kind) in parts where zip.contains(part) {
                if let indices = seen[part] {
                    for i in indices { units[i].slides.append(number); slide.units.append(units[i].id) }
                    continue
                }
                seen[part] = []
                let tree = try document(zip.read(part))
                for (pindex, paragraph) in try descendants(tree, "p", drawingNS).enumerated() {
                    if try !descendants(paragraph, "fld", drawingNS).isEmpty { continue }
                    let texts = try descendants(paragraph, "t", drawingNS)
                    let source = texts.map { $0.stringValue ?? "" }.joined()
                    if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    let i = units.count
                    units.append(TextUnit(id: "u\(i)", part: part, index: pindex, kind: kind, source: source, slides: [number], rich: texts.count > 1))
                    seen[part]!.append(i); slide.units.append("u\(i)")
                }
                if kind == "chart" {
                    for (vindex, value) in try caches(tree).enumerated() {
                        let source = value.stringValue ?? ""
                        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                        let i = units.count
                        units.append(TextUnit(id: "u\(i)", part: part, index: vindex, kind: "chart-cache", source: source, slides: [number]))
                        seen[part]!.append(i); slide.units.append("u\(i)")
                    }
                }
            }
            slides.append(slide)
        }
        return DeckInventory(slides: slides, units: units, slide_count: slides.count, image_count: slides.reduce(0) { $0 + $1.images })
    }
    private static func caches(_ tree: XMLNode) throws -> [XMLElement] {
        try descendants(tree, "strCache", chartNS).flatMap { direct($0, "pt", chartNS) }.flatMap { direct($0, "v", chartNS) }
    }
    static func shouldPreserve(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { return true }
        return text.range(of: "^(?:(?:https?://|www\\.)\\S+|[\\w.+-]+@[\\w.-]+\\.[a-zA-Z]{2,})$", options: .regularExpression) != nil
    }
    static func distribute(_ text: String, originals: [String]) -> [String] {
        guard originals.count > 1 else { return originals.isEmpty ? [] : [text] }
        // Python len counts Unicode scalars; matching it also preserves the old proportional behavior.
        let chars = Array(text.unicodeScalars), total = max(1, originals.reduce(0) { $0 + $1.unicodeScalars.count })
        var previous = 0, done = 0, output: [String] = []
        let latin = text.range(of: "[A-Za-z]", options: .regularExpression) != nil && text.contains(" ")
        let spaces = chars.indices.filter { CharacterSet.whitespacesAndNewlines.contains(chars[$0]) && ($0 + 1 == chars.count || !CharacterSet.whitespacesAndNewlines.contains(chars[$0 + 1])) }.map { $0 + 1 }
        for source in originals.dropLast() {
            done += source.unicodeScalars.count
            var boundary = Int((Double(chars.count) * Double(done) / Double(total)).rounded(.toNearestOrEven))
            if latin, let candidate = spaces.filter({ $0 >= previous }).min(by: { abs($0 - boundary) < abs($1 - boundary) }) { boundary = candidate }
            boundary = min(chars.count, max(previous, boundary))
            output.append(String(String.UnicodeScalarView(chars[previous..<boundary]))); previous = boundary
        }
        output.append(String(String.UnicodeScalarView(chars[previous...]))); return output
    }
    static func export(source: URL, units: [TextUnit], fit: Bool, destination: URL) throws {
        let zip = try ZipArchive(source)
        let grouped = Dictionary(grouping: units.filter { !$0.translation.isEmpty && $0.translation != $0.source }, by: { $0.part })
        var workbooks: [String: [String: String]] = [:], replacements: [String: Data] = [:]
        for (part, values) in grouped {
            let cached = values.filter { $0.kind == "chart-cache" }
            if !cached.isEmpty {
                for rel in try relationships(zip, part) where rel.kind == "package" && rel.target.hasSuffix(".xlsx") {
                    for unit in cached { workbooks[rel.target, default: [:]][unit.source] = unit.translation }
                }
            }
            let tree = try document(zip.read(part))
            let paragraphs = try descendants(tree, "p", drawingNS), cache = try caches(tree)
            for unit in values {
                if unit.kind == "chart-cache" {
                    guard cache.indices.contains(unit.index) else { throw StudioError("グラフの項目が原本と一致しません。") }
                    cache[unit.index].stringValue = unit.translation; continue
                }
                guard paragraphs.indices.contains(unit.index) else { throw StudioError("段落の位置が原本と一致しません。") }
                let p = paragraphs[unit.index], texts = try descendants(p, "t", drawingNS)
                for (node, value) in zipPairs(texts, distribute(unit.translation, originals: texts.map { $0.stringValue ?? "" })) {
                    node.stringValue = value; attribute(node, "xml:space", "preserve", uri: "http://www.w3.org/XML/1998/namespace")
                }
                if fit && !["notes", "shared"].contains(unit.kind), let body = p.parent {
                    for properties in direct(body, "bodyPr", drawingNS) {
                        for old in (properties.children ?? []) where ["noAutofit", "spAutoFit", "normAutofit"].contains(old.localName ?? "") && old.uri == drawingNS { old.detach() }
                        let prefix = properties.prefix ?? "a"
                        let autofit = XMLElement(name: (prefix.isEmpty ? "" : prefix + ":") + "normAutofit", uri: drawingNS)
                        properties.addChild(autofit)
                    }
                }
            }
            tree.characterEncoding = "UTF-8"; replacements[part] = tree.xmlData(options: [.nodePreserveAll])
        }
        for (part, mapping) in workbooks { replacements[part] = try translateWorkbook(zip.read(part), mapping: mapping) }
        try zip.rewrite(destination: destination, replacements: replacements)
    }
    private static func translateWorkbook(_ data: Data, mapping: [String: String]) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SlideLocal-workbook-" + newID())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.xlsx"), output = folder.appendingPathComponent("translated.xlsx")
        try data.write(to: input)
        let zip = try ZipArchive(input)
        var replacements: [String: Data] = [:]
        for entry in zip.entries where entry.name == "xl/sharedStrings.xml" || entry.name.range(of: "^xl/worksheets/sheet[0-9]+\\.xml$", options: .regularExpression) != nil {
            let tree = try document(zip.read(entry.name))
            var changed = false
            for element in try descendants(tree, "si", spreadsheetNS) + descendants(tree, "is", spreadsheetNS) {
                let texts = try descendants(element, "t", spreadsheetNS)
                if let translated = mapping[texts.map({ $0.stringValue ?? "" }).joined()] {
                    for (node, value) in zipPairs(texts, distribute(translated, originals: texts.map { $0.stringValue ?? "" })) { node.stringValue = value; attribute(node, "xml:space", "preserve", uri: "http://www.w3.org/XML/1998/namespace") }
                    changed = true
                }
            }
            if changed { tree.characterEncoding = "UTF-8"; replacements[entry.name] = tree.xmlData(options: [.nodePreserveAll]) }
        }
        try zip.rewrite(destination: output, replacements: replacements)
        return try Data(contentsOf: output)
    }
}
private func zipPairs<A, B>(_ a: [A], _ b: [B]) -> Zip2Sequence<[A], [B]> { zip(a, b) }
