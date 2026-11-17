import Foundation

// Seekable ZIP reader and raw compressed-member copier. Images/video never inflate on export.
private extension Data {
    func integer(_ offset: Int, _ width: Int) throws -> UInt64 {
        guard offset >= 0, width <= count, offset <= count - width else { throw StudioError("ZIPのヘッダーが途中で切れています。") }
        return (0..<width).reduce(UInt64(0)) { $0 | UInt64(self[offset + $1]) << ($1 * 8) }
    }
    mutating func put(_ value: UInt64, _ width: Int) { for i in 0..<width { append(UInt8(truncatingIfNeeded: value >> (i * 8))) } }
}
private func readExactly(_ file: FileHandle, _ count: Int) throws -> Data {
    var data = Data()
    while data.count < count {
        guard let next = try file.read(upToCount: count - data.count), !next.isEmpty else { throw StudioError("ZIPが途中で切れています。") }
        data.append(next)
    }
    return data
}
private func crc(_ data: Data) -> UInt32 { data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) } }
private func transform(_ data: Data, encode: Bool) throws -> Data {
    var stream = z_stream()
    let version = zlibVersion()
    let result = encode ? deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, version, Int32(MemoryLayout<z_stream>.size)) : inflateInit2_(&stream, -MAX_WBITS, version, Int32(MemoryLayout<z_stream>.size))
    guard result == Z_OK else { throw StudioError("ZIPの圧縮処理を初期化できません。") }
    defer { if encode { deflateEnd(&stream) } else { inflateEnd(&stream) } }
    var output = Data(), buffer = [UInt8](repeating: 0, count: 65536)
    try data.withUnsafeBytes { input in
        var offset = 0
        var status: Int32 = Z_OK
        repeat {
            if stream.avail_in == 0 && offset < data.count {
                let count = min(data.count - offset, Int(UInt32.max))
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset))
                stream.avail_in = uInt(count); offset += count
            }
            status = buffer.withUnsafeMutableBytes { dest in
                stream.next_out = dest.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = 65536
                return encode ? deflate(&stream, offset == data.count ? Z_FINISH : Z_NO_FLUSH) : inflate(&stream, Z_NO_FLUSH)
            }
            let written = buffer.count - Int(stream.avail_out)
            output.append(contentsOf: buffer.prefix(written))
            guard status == Z_OK || status == Z_STREAM_END || (encode && status == Z_BUF_ERROR) else { throw StudioError("ZIPの圧縮データが壊れています。") }
            if status != Z_STREAM_END && written == 0 && stream.avail_in == 0 && offset == data.count { throw StudioError("ZIPの圧縮データが途中で切れています。") }
        } while status != Z_STREAM_END
    }
    return output
}

final class ZipArchive {
    struct Entry {
        var name: String; var flags: UInt16; var method: UInt16; var time: UInt16; var date: UInt16
        var checksum: UInt32; var compressed: UInt64; var expanded: UInt64; var offset: UInt64; var attributes: UInt32
    }
    let url: URL
    let file: FileHandle
    private(set) var entries: [Entry] = []
    private var names: [String: Int] = [:]
    init(_ url: URL) throws {
        self.url = url; file = try FileHandle(forReadingFrom: url)
        let size = try file.seekToEnd()
        guard size >= 22 else { throw StudioError("有効なPPTX ZIPではありません。") }
        let tailSize = min(size, 65557)
        try file.seek(toOffset: size - tailSize)
        let tail = try readExactly(file, Int(tailSize))
        var end: Int?
        for i in stride(from: tail.count - 22, through: 0, by: -1) {
            if try tail.integer(i, 4) == 0x06054b50, i + 22 + Int(try tail.integer(i + 20, 2)) == tail.count { end = i; break }
        }
        guard let end else { throw StudioError("ZIPの目次が見つかりません。") }
        guard try tail.integer(end + 4, 2) == 0, try tail.integer(end + 6, 2) == 0 else { throw StudioError("分割ZIPには対応していません。") }
        var count = try tail.integer(end + 10, 2), central = try tail.integer(end + 16, 4)
        if count == 0xffff || central == 0xffffffff {
            let endOffset = size - tailSize + UInt64(end)
            guard endOffset >= 20 else { throw StudioError("ZIP64の目次が不正です。") }
            try file.seek(toOffset: endOffset - 20)
            let locator = try readExactly(file, 20)
            guard try locator.integer(0, 4) == 0x07064b50, try locator.integer(4, 4) == 0, try locator.integer(16, 4) == 1 else { throw StudioError("ZIP64の目次が不正です。") }
            let offset = try locator.integer(8, 8)
            guard offset < size else { throw StudioError("ZIP64の位置が不正です。") }
            try file.seek(toOffset: offset)
            let record = try readExactly(file, 56)
            guard try record.integer(0, 4) == 0x06064b50, try record.integer(16, 4) == 0, try record.integer(20, 4) == 0 else { throw StudioError("ZIP64の目次が不正です。") }
            count = try record.integer(32, 8); central = try record.integer(48, 8)
        }
        guard central < size, count <= (size - central) / 46 else { throw StudioError("ZIPの目次が壊れています。") }
        try file.seek(toOffset: central)
        for _ in 0..<count {
            let header = try readExactly(file, 46)
            guard try header.integer(0, 4) == 0x02014b50 else { throw StudioError("ZIPのエントリーが壊れています。") }
            let flags = UInt16(try header.integer(8, 2)), method = UInt16(try header.integer(10, 2))
            guard flags & 1 == 0, [0, 8].contains(method) else { throw StudioError("暗号化された資料、または未対応のZIP圧縮です。") }
            let nameData = try readExactly(file, Int(header.integer(28, 2)))
            guard let name = String(data: nameData, encoding: .utf8), !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator: "/").contains(".."), names[name] == nil else { throw StudioError("ZIP内のファイル名が不正または重複しています。") }
            let extra = try readExactly(file, Int(header.integer(30, 2)))
            _ = try readExactly(file, Int(header.integer(32, 2)))
            var expanded = try header.integer(24, 4), compressed = try header.integer(20, 4), offset = try header.integer(42, 4)
            var position = 0
            while position < extra.count {
                let kind = try extra.integer(position, 2), length = Int(try extra.integer(position + 2, 2)); position += 4
                guard length <= extra.count - position else { throw StudioError("ZIP拡張情報が壊れています。") }
                if kind == 1 {
                    var j = position
                    if expanded == 0xffffffff { expanded = try extra.integer(j, 8); j += 8 }
                    if compressed == 0xffffffff { compressed = try extra.integer(j, 8); j += 8 }
                    if offset == 0xffffffff { offset = try extra.integer(j, 8); j += 8 }
                    guard j <= position + length else { throw StudioError("ZIP64のサイズが不正です。") }
                }
                position += length
            }
            guard offset < central, compressed <= size else { throw StudioError("ZIP内の位置が不正です。") }
            names[name] = entries.count
            entries.append(Entry(name: name, flags: flags, method: method, time: UInt16(try header.integer(12, 2)), date: UInt16(try header.integer(14, 2)), checksum: UInt32(try header.integer(16, 4)), compressed: compressed, expanded: expanded, offset: offset, attributes: UInt32(try header.integer(38, 4))))
        }
    }
    deinit { try? file.close() }
    func contains(_ name: String) -> Bool { names[name] != nil }
    private func position(_ entry: Entry) throws {
        try file.seek(toOffset: entry.offset)
        let header = try readExactly(file, 30)
        guard try header.integer(0, 4) == 0x04034b50 else { throw StudioError("ZIPのファイルが壊れています。") }
        let skip = try header.integer(26, 2) + header.integer(28, 2)
        try file.seek(toOffset: entry.offset + 30 + skip)
    }
    func read(_ name: String) throws -> Data {
        guard let i = names[name] else { throw StudioError("PPTX内のファイルが見つかりません: " + name) }
        let e = entries[i]; try position(e)
        guard e.compressed <= UInt64(Int.max) else { throw StudioError("このMacで扱えないサイズです。") }
        let content = try readExactly(file, Int(e.compressed))
        let data = try e.method == 0 ? content : transform(content, encode: false)
        guard UInt64(data.count) == e.expanded, crc(data) == e.checksum else { throw StudioError("ZIPのデータ検証に失敗しました: " + name) }
        return data
    }
    func rewrite(destination: URL, replacements: [String: Data]) throws {
        guard destination.standardizedFileURL != url.standardizedFileURL else { throw StudioError("原本を上書きできません。") }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        var written: UInt64 = 0, rewritten: [Entry] = []
        func emit(_ data: Data) throws { try output.write(contentsOf: data); written += UInt64(data.count) }
        do {
            for original in entries {
                try Task.checkCancellation()
                var e = original; e.offset = written; e.flags = 0x800
                let replacement = try replacements[e.name].map { data -> Data in e.expanded = UInt64(data.count); e.checksum = crc(data); e.method = 8; return try transform(data, encode: true) }
                if let replacement { e.compressed = UInt64(replacement.count) }
                let zip64 = e.expanded >= 0xffffffff || e.compressed >= 0xffffffff
                let name = Data(e.name.utf8)
                var extra = Data()
                if zip64 { extra.put(1, 2); extra.put(16, 2); extra.put(e.expanded, 8); extra.put(e.compressed, 8) }
                var header = Data(); header.put(0x04034b50, 4); header.put(zip64 ? 45 : 20, 2); header.put(UInt64(e.flags), 2); header.put(UInt64(e.method), 2); header.put(UInt64(e.time), 2); header.put(UInt64(e.date), 2); header.put(UInt64(e.checksum), 4); header.put(zip64 ? 0xffffffff : e.compressed, 4); header.put(zip64 ? 0xffffffff : e.expanded, 4); header.put(UInt64(name.count), 2); header.put(UInt64(extra.count), 2)
                try emit(header); try emit(name); try emit(extra)
                if let replacement { try emit(replacement) } else {
                    try position(original)
                    var remaining = e.compressed
                    while remaining > 0 { try Task.checkCancellation(); let block = try readExactly(file, Int(min(remaining, 1048576))); try emit(block); remaining -= UInt64(block.count) }
                }
                rewritten.append(e)
            }
            let central = written
            for e in rewritten {
                let largeSize = e.expanded >= 0xffffffff || e.compressed >= 0xffffffff, largeOffset = e.offset >= 0xffffffff
                var extra = Data(), payload = Data()
                if largeSize { payload.put(e.expanded, 8); payload.put(e.compressed, 8) }
                if largeOffset { payload.put(e.offset, 8) }
                if !payload.isEmpty { extra.put(1, 2); extra.put(UInt64(payload.count), 2); extra.append(payload) }
                let name = Data(e.name.utf8)
                var h = Data(); h.put(0x02014b50, 4); h.put(0x033f, 2); h.put(payload.isEmpty ? 20 : 45, 2); h.put(UInt64(e.flags), 2); h.put(UInt64(e.method), 2); h.put(UInt64(e.time), 2); h.put(UInt64(e.date), 2); h.put(UInt64(e.checksum), 4); h.put(largeSize ? 0xffffffff : e.compressed, 4); h.put(largeSize ? 0xffffffff : e.expanded, 4); h.put(UInt64(name.count), 2); h.put(UInt64(extra.count), 2); h.put(0, 2); h.put(0, 2); h.put(0, 2); h.put(UInt64(e.attributes), 4); h.put(largeOffset ? 0xffffffff : e.offset, 4)
                try emit(h); try emit(name); try emit(extra)
            }
            let centralSize = written - central, count = UInt64(rewritten.count)
            if central >= 0xffffffff || centralSize >= 0xffffffff || count >= 0xffff {
                let start = written
                var h = Data(); h.put(0x06064b50, 4); h.put(44, 8); h.put(45, 2); h.put(45, 2); h.put(0, 4); h.put(0, 4); h.put(count, 8); h.put(count, 8); h.put(centralSize, 8); h.put(central, 8)
                try emit(h)
                var locator = Data(); locator.put(0x07064b50, 4); locator.put(0, 4); locator.put(start, 8); locator.put(1, 4); try emit(locator)
            }
            var end = Data(); end.put(0x06054b50, 4); end.put(0, 2); end.put(0, 2); end.put(min(count, 0xffff), 2); end.put(min(count, 0xffff), 2); end.put(min(centralSize, 0xffffffff), 4); end.put(min(central, 0xffffffff), 4); end.put(0, 2); try emit(end)
            try output.synchronize(); try output.close()
        } catch { try? output.close(); try? FileManager.default.removeItem(at: destination); throw error }
    }
}
