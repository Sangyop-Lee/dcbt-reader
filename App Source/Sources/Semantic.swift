import Foundation
import Accelerate

/// Meaning-based search. Every text is cut into passages of roughly 100
/// characters; each passage is turned into a vector by a language model
/// (BGE-M3 if installed, otherwise the Mac's built-in one), and a query is
/// matched by vector similarity.
struct SemHit {
    var textIndex: Int
    var line: Int           // global line index of the passage start
    var lineCount: Int
    var dispStart: Int      // the passage itself, as offsets into the display text
    var dispEnd: Int
    var score: Float
}

/// One passage: whole sentences where the text is punctuated, printed lines where it is not.
struct Chunk {
    var line: Int           // global index of the line it starts in
    var count: Int          // lines it touches
    var dispStart: Int
    var dispEnd: Int
}

final class SemanticIndex {
    static let fileVersion: UInt32 = 6
    let ix: CorpusIndex
    let dir: URL
    let embedder: TextEmbedder
    let size: PassageSize
    var dim: Int { embedder.dim }

    private struct Block {
        var chunkLines: [UInt32]    // global line index
        var chunkCounts: [UInt32]
        var chunkDisp: [UInt32]     // display offset (global)
        var chunkLen: [UInt32]
        var norms: [Float]
        var vectors: Data           // count * dim Int8
    }
    private var blocks: [Int: Block] = [:]
    private let lock = NSLock()
    private var cancelled = false
    private var ready = false

    /// The window passes `load: false` and reads the stored index in the background, the first time
    /// by-meaning search is used: it is thousands of files, and launching must not wait for them.
    private(set) var loaded = false

    init(ix: CorpusIndex, dir: URL, embedder: TextEmbedder, size: PassageSize = .large, load: Bool = true) {
        self.ix = ix
        self.embedder = embedder
        self.size = size
        self.dir = dir.appendingPathComponent(embedder.key, isDirectory: true).appendingPathComponent(size.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
        if load { loadAll() }
    }

    /// BGE-M3 from the "Language model" folder if it is there, else Apple's model.
    static func bestEmbedder() -> TextEmbedder? {
        if let d = AppPaths.modelDir, let e = BGEEmbedder(dir: d) { return e }
        return AppleEmbedder.available ? AppleEmbedder() : nil
    }

    var indexedCount: Int { lock.lock(); defer { lock.unlock() }; return blocks.count }
    func isIndexed(_ ti: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return blocks[ti] != nil }
    func cancel() { cancelled = true }

    // MARK: chunking

    @inline(__always) private static func isStop(_ c: UInt16) -> Bool {
        c == 0x3002 || c == 0xFF01 || c == 0xFF1F || c == 0xFF1B || c == 0x2026 || c == 0xFF0E   // 。！？；…．
    }
    @inline(__always) private static func isCloser(_ c: UInt16) -> Bool {
        c == 0x300D || c == 0x300F || c == 0xFF09 || c == 0x3011 || c == 0x300B || c == 0x201D || c == 0x2019   // 」』）】》”’
    }
    @inline(__always) private static func isPause(_ c: UInt16) -> Bool {
        c == 0xFF0C || c == 0x3001 || c == 0xFF1A || c == 0x3000 || c == 0x20      // ，、： and spaces
    }

    /// Cuts a text into passages for the language model.
    ///
    /// Where the text has sentence punctuation, a passage is a run of whole
    /// sentences, closed at the first sentence end after about 120 characters.
    /// Where it has none (or almost none), the printed lines of the edition
    /// are used instead.
    func chunks(for ti: Int) -> [Chunk] {
        let t = ix.texts[ti]
        let a = t.dispStart, b = t.dispEnd
        if b - a < 12 || t.lineCount == 0 { return [] }
        let p = ix.display
        let target = size.target, longest = size.longest
        // titles, bylines and catalogue lines are left out; each stretch between them is cut on its own
        var segments: [(Int, Int)] = []
        var at = a
        for (s0, e0) in ix.skips(text: ti) {
            if s0 > at { segments.append((at, min(s0, b))) }
            at = max(at, e0)
        }
        if at < b { segments.append((at, b)) }

        var stops = 0, content = 0
        for (s0, e0) in segments {
            content += e0 - s0
            var i = s0
            while i < e0 { if SemanticIndex.isStop(p[i]) { stops += 1 }; i += 1 }
        }
        // punctuated = on average at least one sentence end every 400 characters
        if stops < max(1, content / 400) { return lineChunks(for: ti) }

        var spans: [(Int, Int)] = []
        for (s0, e0) in segments {
            let firstSpan = spans.count
            var start = s0
            var i = s0
            while i <= e0 {
                var e = -1
                if i == e0 { e = e0 }
                else if SemanticIndex.isStop(p[i]) {
                    var j = i + 1
                    while j < e0, SemanticIndex.isStop(p[j]) || SemanticIndex.isCloser(p[j]) { j += 1 }
                    e = j
                }
                if e < 0 { i += 1; continue }
                // a sentence too long for the model: cut at a comma or pause, else outright
                while e - start > longest {
                    var cut = start + longest
                    var k = cut
                    while k > start + longest / 2 { if SemanticIndex.isPause(p[k - 1]) { cut = k; break }; k -= 1 }
                    if p[cut] >= 0xDC00 && p[cut] <= 0xDFFF { cut -= 1 }
                    spans.append((start, cut))
                    start = cut
                }
                if e - start >= target { spans.append((start, e)); start = e }
                i = max(e, i + 1)
            }
            if start < e0 {
                // what is left of this stretch: join a short tail to the passage before it
                if e0 - start < target / 3, spans.count > firstSpan, let last = spans.last, last.1 == start,
                   e0 - last.0 <= longest { spans[spans.count - 1] = (last.0, e0) }
                else if e0 - start >= 6 { spans.append((start, e0)) }
            }
        }
        // the lines each passage starts and ends in
        var out: [Chunk] = []
        out.reserveCapacity(spans.count)
        var li = t.firstLine
        let lastLine = t.firstLine + t.lineCount - 1
        for (s0, e0) in spans {
            while li < lastLine, Int(ix.lines[li + 1].dispStart) <= s0 { li += 1 }
            var le = li
            while le < lastLine, Int(ix.lines[le + 1].dispStart) < e0 { le += 1 }
            out.append(Chunk(line: li, count: le - li + 1, dispStart: s0, dispEnd: e0))
        }
        return out
    }

    /// Passages made of whole printed lines, for texts without sentence punctuation.
    private func lineChunks(for ti: Int) -> [Chunk] {
        let t = ix.texts[ti]
        var out: [Chunk] = []
        var start = t.firstLine
        let end = t.firstLine + t.lineCount
        func disp(_ line: Int) -> Int { line < end ? Int(ix.lines[line].dispStart) : t.dispEnd }
        var li = start
        while li < end {
            let next = li + 1 < end ? Int(ix.lines[li + 1].searchStart) : t.searchEnd
            let units = next - Int(ix.lines[start].searchStart)
            if units >= size.target * 5 / 6 || li == end - 1 {
                if units < size.target * 2 / 5, let last = out.last, last.line + last.count == start {
                    out[out.count - 1].count = li - last.line + 1
                    out[out.count - 1].dispEnd = disp(li + 1)
                } else if units >= 6 {
                    out.append(Chunk(line: start, count: li - start + 1, dispStart: disp(start), dispEnd: disp(li + 1)))
                }
                start = li + 1
            }
            li += 1
        }
        return out
    }

    func chunkText(_ a: Int, _ b: Int, limit: Int = 260) -> String {
        var e = min(b, a + limit)
        if e < b, ix.display[e] >= 0xDC00 && ix.display[e] <= 0xDFFF { e -= 1 }
        return ix.displayString(a, e)
    }
    func text(of h: SemHit, limit: Int = 260) -> String { chunkText(h.dispStart, h.dispEnd, limit: limit) }

    // MARK: model

    /// Loads (and if necessary calibrates) the language model. Safe to call repeatedly.
    func prepare(status: (String) -> Void) -> Bool {
        lock.lock(); let r = ready; lock.unlock()
        if r { return true }
        let ok = embedder.prepare(dir: dir, samples: {
            var out: [String] = []
            let step = max(self.ix.texts.count / 1200, 1)
            var ti = 0
            while ti < self.ix.texts.count {
                let c = self.chunks(for: ti)
                if !c.isEmpty { let m = c[c.count / 2]; out.append(self.chunkText(m.dispStart, m.dispEnd)) }
                ti += step
            }
            return out
        }, status: status)
        lock.lock(); ready = ok; lock.unlock()
        return ok
    }

    func embed(_ texts: [String]) -> [[Float]?] { embedder.embed(texts, size: size) }

    // MARK: build

    /// Embeds the given texts (skipping ones already done). Returns false if the model is unavailable.
    @discardableResult
    func build(texts: [Int], progress: @escaping (_ doneTexts: Int, _ totalTexts: Int, _ status: String) -> Void) -> Bool {
        cancelled = false
        let todo = texts.filter { !isIndexed($0) }
        if todo.isEmpty { return true }
        guard prepare(status: { progress(0, todo.count, $0) }) else { return false }
        var totalChunks = 0
        var doneChunks = 0
        let lists = todo.map { chunks(for: $0) }
        for c in lists { totalChunks += c.count }
        let t0 = Date()
        let dim = self.dim
        let slice = 512
        for (k, ti) in todo.enumerated() {
            if cancelled { break }
            let cs = lists[k]
            var vecs = [Int8](repeating: 0, count: cs.count * dim)
            var norms = [Float](repeating: 0, count: cs.count)
            var at = 0
            while at < cs.count && !cancelled {
                let part = Array(cs[at..<min(at + slice, cs.count)])
                let out = embedder.embed(part.map { chunkText($0.dispStart, $0.dispEnd) }, size: size)
                for (j, v) in out.enumerated() {
                    guard let v = v else { continue }
                    var mx: Float = 0
                    vDSP_maxmgv(v, 1, &mx, vDSP_Length(dim))
                    if mx <= 0 { continue }
                    let scale = 127 / mx
                    var sq: Float = 0
                    let i = at + j
                    for d in 0..<dim {
                        let q = Int8(max(-127, min(127, (v[d] * scale).rounded())))
                        vecs[i * dim + d] = q
                        sq += Float(q) * Float(q)
                    }
                    norms[i] = sq.squareRoot()
                }
                at += part.count
                let done = doneChunks + at
                let rate = Double(done) / max(Date().timeIntervalSince(t0), 0.001)
                let remain = Double(totalChunks - done) / max(rate, 0.001)
                let eta = remain > 5400 ? String(format: "%.1f h left", remain / 3600) : remain > 90 ? "\(Int(remain / 60)) min left" : "\(Int(remain)) s left"
                progress(k, todo.count, "Reading \(ix.texts[ti].title) — \(eta)")
            }
            if cancelled { break }
            let block = Block(chunkLines: cs.map { UInt32($0.line) }, chunkCounts: cs.map { UInt32($0.count) },
                              chunkDisp: cs.map { UInt32($0.dispStart) }, chunkLen: cs.map { UInt32($0.dispEnd - $0.dispStart) },
                              norms: norms, vectors: vecs.withUnsafeBufferPointer { Data(buffer: $0) })
            save(block, ti)
            lock.lock(); blocks[ti] = block; lock.unlock()
            doneChunks += cs.count
            progress(k + 1, todo.count, "")
        }
        return true
    }

    private func fileURL(_ ti: Int) -> URL { dir.appendingPathComponent(ix.texts[ti].id + ".sem") }

    private func save(_ b: Block, _ ti: Int) {
        var d = Data()
        var header: [UInt32] = [0x53424344, SemanticIndex.fileVersion, UInt32(dim), UInt32(b.chunkLines.count),
                                UInt32(ix.texts[ti].lineCount), UInt32(truncatingIfNeeded: ix.texts[ti].searchEnd - ix.texts[ti].searchStart)]
        header.withUnsafeMutableBufferPointer { d.append(Data(buffer: $0)) }
        let first = UInt32(ix.texts[ti].firstLine)
        b.chunkLines.map { $0 - first }.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        b.chunkCounts.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        let disp0 = UInt32(ix.texts[ti].dispStart)
        b.chunkDisp.map { $0 - disp0 }.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        b.chunkLen.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        b.norms.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        d.append(b.vectors)
        try? d.write(to: fileURL(ti), options: .atomic)
    }

    /// Picks up index files written since the last look (a build may still be running).
    func refresh() {
        if !loaded || indexedCount < ix.texts.count { loadAll() }
    }

    private func loadAll() {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in items where u.pathExtension == "sem" {
            let id = u.deletingPathExtension().lastPathComponent
            guard let ti = ix.textIndexById[id], !isIndexed(ti),
                  let d = try? Data(contentsOf: u, options: .alwaysMapped), d.count >= 24 else { continue }
            let h: [UInt32] = d.prefix(24).withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            let t = ix.texts[ti]
            let n = Int(h[3])
            guard h[0] == 0x53424344, h[1] == SemanticIndex.fileVersion, Int(h[2]) == dim,
                  Int(h[4]) == t.lineCount, h[5] == UInt32(truncatingIfNeeded: t.searchEnd - t.searchStart),
                  d.count == 24 + n * 20 + n * dim else { continue }
            func arr<T>(_ off: Int, _ type: T.Type) -> [T] {
                d.subdata(in: off..<(off + n * 4)).withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
            }
            let first = UInt32(t.firstLine)
            let disp0 = UInt32(t.dispStart)
            let b = Block(chunkLines: arr(24, UInt32.self).map { $0 + first }, chunkCounts: arr(24 + n * 4, UInt32.self),
                          chunkDisp: arr(24 + n * 8, UInt32.self).map { $0 + disp0 }, chunkLen: arr(24 + n * 12, UInt32.self),
                          norms: arr(24 + n * 16, Float.self),
                          vectors: d[(24 + n * 20)..<d.count])    // left in the mapped file: read from disk only when searched
            lock.lock(); blocks[ti] = b; lock.unlock()
        }
        loaded = true
    }

    // MARK: query

    /// Nearest stored passages to an already embedded query.
    func search(vector q: [Float], scope: [Bool]?, topK: Int = 300) -> [SemHit] {
        lock.lock()
        let items = blocks.filter { scope?[$0.key] ?? true }.sorted { $0.key < $1.key }
        lock.unlock()
        if items.isEmpty { return [] }
        var parts = [[SemHit]](repeating: [], count: items.count)
        let dim = self.dim
        parts.withUnsafeMutableBufferPointer { pp in
            let out = pp.baseAddress!
            DispatchQueue.concurrentPerform(iterations: items.count) { k in
                let (ti, b) = items[k]
                var local: [SemHit] = []
                var tmp = [Float](repeating: 0, count: dim)
                b.vectors.withUnsafeBytes { raw in
                    let base = raw.bindMemory(to: Int8.self).baseAddress!
                    for i in 0..<b.chunkLines.count where b.norms[i] > 0 {
                        vDSP_vflt8(base + i * dim, 1, &tmp, 1, vDSP_Length(dim))
                        var dot: Float = 0
                        vDSP_dotpr(tmp, 1, q, 1, &dot, vDSP_Length(dim))
                        local.append(SemHit(textIndex: ti, line: Int(b.chunkLines[i]), lineCount: Int(b.chunkCounts[i]),
                                            dispStart: Int(b.chunkDisp[i]), dispEnd: Int(b.chunkDisp[i]) + Int(b.chunkLen[i]), score: dot / b.norms[i]))
                    }
                }
                local.sort { $0.score > $1.score }
                if local.count > topK { local.removeLast(local.count - topK) }
                (out + k).pointee = local
            }
        }
        var all = parts.flatMap { $0 }
        all.sort { $0.score > $1.score }
        if all.count > topK { all.removeLast(all.count - topK) }
        return all
    }

}

// MARK: - Search by meaning

extension SemanticIndex {
    /// The passages closest in meaning to the query, from the stored index only.
    /// Texts whose passages have not been read by the model yet are not covered.
    func similar(_ query: String, scope: [Bool]?, topK: Int = 200, status: (String) -> Void = { _ in }) -> [SemHit] {
        refresh()
        guard indexedCount > 0, prepare(status: status), let q = embed([query]).first ?? nil else { return [] }
        return search(vector: q, scope: scope, topK: topK)
    }
}
