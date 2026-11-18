import Foundation

// MARK: - On-disk model

struct JuanInfo: Codable {
    var n: Int              // juan number as printed
    var line: Int           // index (within the text) of its first line
    var searchStart: Int    // offset (within the text) in the search stream
}

struct TextInfo: Codable, Identifiable {
    var id: String          // "T01n0001"
    var canon: String       // "T" / "X"
    var vol: Int
    var no: String          // "0001", "0128a"
    var title: String
    var author: String
    var era: String
    var extent: String
    var path: String        // relative to the source folder
    var firstLine: Int
    var lineCount: Int
    var searchStart: Int
    var searchEnd: Int
    var dispStart: Int
    var dispEnd: Int
    var juans: [JuanInfo]
    var witnesses: [String]
    var firstSkip = 0       // index of this text's first pair in skips.bin
    var skipCount = 0       // number of pairs
}

struct IndexMeta: Codable {
    var version: Int
    var built: Date
    var sourcePath: String
    var fileCount: Int
    var searchUnits: Int
    var displayUnits: Int
    var lineCount: Int
}

struct LineRec {
    var searchStart: UInt32
    var dispStart: UInt32
    var lbn: UInt64          // up to 8 ASCII bytes, little-endian
}

let indexVersion = 4

func packLbn(_ s: String) -> UInt64 {
    var v: UInt64 = 0
    var shift: UInt64 = 0
    for b in s.utf8.prefix(8) { v |= UInt64(b) << shift; shift += 8 }
    return v
}

func unpackLbn(_ v: UInt64) -> String {
    var bytes: [UInt8] = []
    var x = v
    while x != 0 { bytes.append(UInt8(x & 0xFF)); x >>= 8 }
    return String(decoding: bytes, as: UTF8.self)
}

/// "0001a02" -> "1a02"
func prettyLbn(_ s: String) -> String {
    var t = Substring(s)
    while t.count > 4, t.first == "0" { t = t.dropFirst() }
    return String(t)
}

// MARK: - Segmentation shared by indexer and reader

struct FileBuild {
    var info: TextInfo
    var search: [UInt16] = []
    var display: [UInt16] = []
    var lines: [LineRec] = []
    var skips: [UInt32] = []    // pairs (start, end) of display offsets holding titles, bylines and catalogue lines
}

func buildFile(doc: ParsedDoc, relPath: String) -> FileBuild {
    var search: [UInt16] = []
    var display: [UInt16] = []
    var lines: [LineRec] = []
    var juans: [JuanInfo] = []
    var skips: [UInt32] = []
    search.reserveCapacity(1 << 16)
    display.reserveCapacity(1 << 16)
    for tok in doc.toks {
        switch tok {
        case .lb(let n):
            lines.append(LineRec(searchStart: UInt32(search.count), dispStart: UInt32(display.count), lbn: packLbn(n)))
        case .juan(let n):
            juans.append(JuanInfo(n: n, line: lines.count, searchStart: search.count))
        case .text(let s, let st):
            if lines.isEmpty {
                lines.append(LineRec(searchStart: 0, dispStart: 0, lbn: packLbn("0000a00")))
            }
            let before = UInt32(display.count)
            display.append(contentsOf: s.utf16)
            if !st.contains(.displayOnly) { appendSearchUnits(s, to: &search) }
            if st.contains(.head) || st.contains(.byline) || st.contains(.front) {
                // headings, bylines and catalogue lines are not content: by-meaning search leaves them out
                if let last = skips.last, last == before { skips[skips.count - 1] = UInt32(display.count) }
                else { skips.append(before); skips.append(UInt32(display.count)) }
            }
        case .para, .anchor, .section:
            break
        }
    }
    if juans.isEmpty || juans[0].searchStart > 0 {
        juans.insert(JuanInfo(n: juans.first.map { max($0.n - 1, 0) } ?? 1, line: 0, searchStart: 0), at: 0)
    }
    for i in juans.indices { juans[i].line = min(juans[i].line, max(lines.count - 1, 0)) }

    let id = doc.id
    let canon = String(id.prefix { $0.isLetter })
    let rest = id.dropFirst(canon.count)
    let parts = rest.split(separator: "n", maxSplits: 1)
    let vol = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
    let no = parts.count > 1 ? String(parts[1]) : ""
    let info = TextInfo(id: id, canon: canon, vol: vol, no: no, title: doc.title, author: doc.author,
                        era: eraFromByline(doc.author), extent: doc.extent, path: relPath,
                        firstLine: 0, lineCount: lines.count, searchStart: 0, searchEnd: search.count,
                        dispStart: 0, dispEnd: display.count, juans: juans, witnesses: doc.witnessLabels)
    return FileBuild(info: info, search: search, display: display, lines: lines, skips: skips)
}

// MARK: - Index building

enum IndexError: Error, LocalizedError {
    case noSource(String)
    case io(String)
    var errorDescription: String? {
        switch self {
        case .noSource(let s): return "No XML files found in \(s)"
        case .io(let s): return s
        }
    }
}

func listSourceFiles(_ source: URL) -> [(URL, String)] {
    var out: [(URL, String)] = []
    let fm = FileManager.default
    guard let en = fm.enumerator(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
    let base = source.standardizedFileURL.path
    for case let u as URL in en where u.pathExtension.lowercased() == "xml" {
        let p = u.standardizedFileURL.path
        var rel = p.hasPrefix(base) ? String(p.dropFirst(base.count)) : u.lastPathComponent
        if rel.hasPrefix("/") { rel.removeFirst() }
        out.append((u, rel))
    }
    out.sort { $0.1 < $1.1 }
    return out
}

func buildIndex(source: URL, dest: URL, progress: @escaping (Int, Int) -> Void) throws {
    let files = listSourceFiles(source)
    guard !files.isEmpty else { throw IndexError.noSource(source.path) }
    let fm = FileManager.default
    let tmp = dest.appendingPathComponent("building-\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    var results = [FileBuild?](repeating: nil, count: files.count)
    let lock = NSLock()
    var done = 0
    results.withUnsafeMutableBufferPointer { buf in
        let p = buf.baseAddress!
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            autoreleasepool {
                if let doc = CBETAParser.parse(url: files[i].0) {
                    let fb = buildFile(doc: doc, relPath: files[i].1)
                    lock.lock(); (p + i).pointee = fb; lock.unlock()
                }
                lock.lock(); done += 1; let d = done; lock.unlock()
                if d % 20 == 0 || d == files.count { progress(d, files.count) }
            }
        }
    }

    func open(_ name: String) throws -> FileHandle {
        let u = tmp.appendingPathComponent(name)
        fm.createFile(atPath: u.path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: u.path) else { throw IndexError.io("Cannot write \(u.path)") }
        return h
    }
    let hs = try open("search.u16"), hd = try open("display.u16"), hl = try open("lines.bin"), hk = try open("skips.bin")
    var texts: [TextInfo] = []
    var sOff = 0, dOff = 0, lOff = 0, kOff = 0
    for i in results.indices {
        guard var fb = results[i] else { continue }
        results[i] = nil
        fb.info.firstLine = lOff
        fb.info.searchStart = sOff
        fb.info.searchEnd = sOff + fb.search.count
        fb.info.dispStart = dOff
        fb.info.dispEnd = dOff + fb.display.count
        for k in fb.lines.indices {
            fb.lines[k].searchStart += UInt32(sOff)
            fb.lines[k].dispStart += UInt32(dOff)
        }
        fb.info.firstSkip = kOff
        fb.info.skipCount = fb.skips.count / 2
        for k in fb.skips.indices { fb.skips[k] += UInt32(dOff) }
        fb.skips.withUnsafeBufferPointer { hk.write(Data(buffer: $0)) }
        kOff += fb.skips.count / 2
        fb.search.append(0)     // separator: never matches a query
        fb.search.withUnsafeBufferPointer { hs.write(Data(buffer: $0)) }
        fb.display.withUnsafeBufferPointer { hd.write(Data(buffer: $0)) }
        fb.lines.withUnsafeBufferPointer { hl.write(Data(buffer: $0)) }
        sOff += fb.search.count
        dOff += fb.display.count
        lOff += fb.lines.count
        texts.append(fb.info)
    }
    try hs.close(); try hd.close(); try hl.close(); try hk.close()
    guard sOff < Int(UInt32.max), dOff < Int(UInt32.max) else { throw IndexError.io("Corpus too large for this index format") }
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    try enc.encode(texts).write(to: tmp.appendingPathComponent("texts.json"))
    let meta = IndexMeta(version: indexVersion, built: Date(), sourcePath: source.path, fileCount: texts.count,
                         searchUnits: sOff, displayUnits: dOff, lineCount: lOff)
    try enc.encode(meta).write(to: tmp.appendingPathComponent("meta.json"))
    for name in ["search.u16", "display.u16", "lines.bin", "skips.bin", "texts.json", "meta.json"] {
        let target = dest.appendingPathComponent(name)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: tmp.appendingPathComponent(name), to: target)
    }
}

// MARK: - Loaded index

final class CorpusIndex {
    let meta: IndexMeta
    let texts: [TextInfo]
    let textIndexById: [String: Int]
    private let sData: Data, dData: Data, lData: Data
    let search: UnsafePointer<UInt16>
    let searchCount: Int
    let display: UnsafePointer<UInt16>
    let lines: UnsafePointer<LineRec>
    let lineCount: Int
    private let textStarts: [Int]
    private let kData: Data

    /// Display ranges of a text that are titles, bylines or catalogue lines.
    func skips(text ti: Int) -> [(Int, Int)] {
        let t = texts[ti]
        return kData.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt32.self)
            return (0..<t.skipCount).compactMap { k in
                let i = (t.firstSkip + k) * 2
                return i + 1 < p.count ? (Int(p[i]), Int(p[i + 1])) : nil
            }
        }
    }

    init?(dir: URL) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let m = try? dec.decode(IndexMeta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json"))),
              m.version == indexVersion,
              let t = try? dec.decode([TextInfo].self, from: Data(contentsOf: dir.appendingPathComponent("texts.json"))),
              let s = try? Data(contentsOf: dir.appendingPathComponent("search.u16"), options: .alwaysMapped),
              let d = try? Data(contentsOf: dir.appendingPathComponent("display.u16"), options: .alwaysMapped),
              let l = try? Data(contentsOf: dir.appendingPathComponent("lines.bin"), options: .alwaysMapped),
              let k = try? Data(contentsOf: dir.appendingPathComponent("skips.bin")),
              s.count == m.searchUnits * 2, d.count == m.displayUnits * 2,
              l.count == m.lineCount * MemoryLayout<LineRec>.stride
        else { return nil }
        meta = m; texts = t; sData = s; dData = d; lData = l; kData = k
        searchCount = m.searchUnits; lineCount = m.lineCount
        search = sData.withUnsafeBytes { $0.bindMemory(to: UInt16.self).baseAddress! }
        display = dData.withUnsafeBytes { $0.bindMemory(to: UInt16.self).baseAddress! }
        lines = lData.withUnsafeBytes { $0.bindMemory(to: LineRec.self).baseAddress! }
        textStarts = t.map { $0.searchStart }
        var map: [String: Int] = [:]
        for (i, x) in t.enumerated() { map[x.id] = i }
        textIndexById = map
    }

    /// Index of the text containing a global search offset.
    func textIndex(at off: Int) -> Int {
        var lo = 0, hi = textStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if textStarts[mid] <= off { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Global line index containing a global search offset, within text `ti`.
    func lineIndex(at off: Int, text ti: Int) -> Int {
        let t = texts[ti]
        var lo = t.firstLine, hi = t.firstLine + t.lineCount - 1
        if hi < lo { return lo }
        let o = UInt32(off)
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].searchStart <= o { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func juanIndex(at off: Int, text ti: Int) -> Int {
        let t = texts[ti]
        let rel = off - t.searchStart
        var k = 0
        for (i, j) in t.juans.enumerated() where j.searchStart <= rel { k = i }
        return k
    }

    /// Display offset corresponding to a global search offset.
    func displayOffset(forSearch off: Int, text ti: Int) -> Int {
        let t = texts[ti]
        let li = lineIndex(at: off, text: ti)
        var need = off - Int(lines[li].searchStart)
        var d = Int(lines[li].dispStart)
        let end = t.dispEnd
        while d < end {
            let u = display[d]
            var v = UInt32(u)
            var width = 1
            if u >= 0xD800 && u <= 0xDBFF && d + 1 < end {
                let lo = display[d + 1]
                v = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(lo) - 0xDC00)
                width = 2
            }
            if isSearchScalar(v) {
                if need <= 0 { return d }
                need -= width
            }
            d += width
        }
        return end
    }

    func displayString(_ a: Int, _ b: Int) -> String {
        guard b > a else { return "" }
        return String(utf16CodeUnits: display + a, count: b - a)
    }
}

// MARK: - Result snippets

extension CorpusIndex {
    struct Snippet {
        var segs: [(text: String, hit: Bool)]
        var textIndex: Int
        var lbn: String
        var juan: Int
    }

    private func displayEnd(forSearchEnd e: Int, start: Int, text ti: Int) -> Int {
        let t = texts[ti]
        let d = displayOffset(forSearch: max(e - 1, start), text: ti)
        if d >= t.dispEnd { return t.dispEnd }
        let w = (display[d] >= 0xD800 && display[d] <= 0xDBFF) ? 2 : 1
        return min(d + w, t.dispEnd)
    }

    /// Text around a hit, split into plain and highlighted pieces.
    func snippet(start: Int, end: Int, marks: [(Int, Int)], before: Int = 14, after: Int = 30) -> Snippet {
        let ti = textIndex(at: start)
        let t = texts[ti]
        let li = lineIndex(at: start, text: ti)
        var spans: [(Int, Int)] = []
        for m in (marks.isEmpty ? [(start, end)] : marks) {
            let ds = displayOffset(forSearch: m.0, text: ti)
            let de = max(displayEnd(forSearchEnd: m.1, start: m.0, text: ti), ds)
            spans.append((ds, de))
        }
        spans.sort { $0.0 < $1.0 }
        var a = max(spans[0].0 - before, t.dispStart)
        if a > t.dispStart, display[a] >= 0xDC00 && display[a] <= 0xDFFF { a -= 1 }
        var b = min(spans[spans.count - 1].1 + after, t.dispEnd)
        if b < t.dispEnd, display[b] >= 0xDC00 && display[b] <= 0xDFFF { b -= 1 }
        var segs: [(String, Bool)] = []
        var cur = a
        for (ds, de) in spans {
            if ds > cur { segs.append((displayString(cur, ds), false)) }
            if de > max(ds, cur) { segs.append((displayString(max(ds, cur), de), true)) }
            cur = max(cur, de)
        }
        if b > cur { segs.append((displayString(cur, b), false)) }
        return Snippet(segs: segs, textIndex: ti, lbn: unpackLbn(lines[li].lbn), juan: juanIndex(at: start, text: ti))
    }
}
