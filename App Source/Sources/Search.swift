import Foundation

// MARK: - Patterns

/// A compiled keyword pattern: literal segments separated by wildcard gaps.
/// `?` matches exactly one character, `*` matches 0...maxStar characters.
struct Pattern {
    var lits: [[UInt16]] = []
    var gaps: [(min: Int, max: Int)] = []   // gaps[i] sits between lits[i] and lits[i+1]

    var isEmpty: Bool { lits.isEmpty }

    static func compile(_ q: String, maxStar: Int) -> Pattern {
        var p = Pattern()
        var cur: [UInt16] = []
        var gmin = 0, gmax = 0
        var pendingGap = false
        for ch in q {
            if ch == "?" || ch == "\u{FF1F}" {
                if !cur.isEmpty { p.lits.append(cur); cur = [] }
                gmin += 1; gmax += 1; pendingGap = true
            } else if ch == "*" || ch == "\u{FF0A}" {
                if !cur.isEmpty { p.lits.append(cur); cur = [] }
                gmax += maxStar; pendingGap = true
            } else {
                let u = searchUnits(String(ch))
                if u.isEmpty { continue }
                if pendingGap {
                    if !p.lits.isEmpty { p.gaps.append((gmin, gmax)) }
                    gmin = 0; gmax = 0; pendingGap = false
                }
                cur.append(contentsOf: u)
            }
        }
        if !cur.isEmpty { p.lits.append(cur) }
        while p.gaps.count > max(p.lits.count - 1, 0) { p.gaps.removeLast() }
        return p
    }
}

struct Hit {
    var start: UInt32
    var end: UInt32
    var sub: Int32 = -1     // index into SearchResult.subSpans (proximity), or -1
}

struct SearchResult {
    var hits: [Hit] = []
    var subSpans: [UInt32] = []     // flattened (start,end) pairs, `termCount` pairs per hit
    var termCount = 0
    var truncated = false
}

let maxHits = 1_000_000

// MARK: - Engine

final class SearchEngine {
    let ix: CorpusIndex
    init(_ ix: CorpusIndex) { self.ix = ix }

    /// Contiguous search-stream ranges covered by the selected texts.
    func ranges(scope: [Bool]?) -> [Range<Int>] {
        guard let scope = scope else { return [0..<ix.searchCount] }
        var out: [Range<Int>] = []
        var cur: Range<Int>? = nil
        for (i, t) in ix.texts.enumerated() {
            if scope[i] {
                if let c = cur, c.upperBound + 1 >= t.searchStart { cur = c.lowerBound..<t.searchEnd }
                else { if let c = cur { out.append(c) }; cur = t.searchStart..<t.searchEnd }
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    /// All occurrences of a literal inside the given ranges (sorted).
    func findLiteral(_ lit: [UInt16], ranges: [Range<Int>], limit: Int = maxHits) -> [UInt32] {
        guard !lit.isEmpty else { return [] }
        let m = lit.count
        var work: [(Range<Int>, Int)] = []      // (chunk, hard end of the enclosing range)
        let chunk = 4 << 20
        for r in ranges {
            var a = r.lowerBound
            while a < r.upperBound {
                let b = min(a + chunk, r.upperBound)
                work.append((a..<b, r.upperBound))
                a = b
            }
        }
        var parts = [[UInt32]](repeating: [], count: work.count)
        let base = UnsafeRawPointer(ix.search)
        lit.withUnsafeBufferPointer { nb in
            let needle = UnsafeRawPointer(nb.baseAddress!)
            parts.withUnsafeMutableBufferPointer { pp in
                let out = pp.baseAddress!
                DispatchQueue.concurrentPerform(iterations: work.count) { w in
                    let (r, hardEnd) = work[w]
                    let stop = min(r.upperBound + m - 1, hardEnd)
                    var pos = r.lowerBound
                    var local: [UInt32] = []
                    while pos + m <= stop {
                        guard let f = memmem(base + pos * 2, (stop - pos) * 2, needle, m * 2) else { break }
                        let byteOff = base.distance(to: UnsafeRawPointer(f))
                        if byteOff & 1 == 1 { pos = byteOff / 2 + 1; continue }
                        let at = byteOff / 2
                        if at >= r.upperBound { break }
                        local.append(UInt32(at))
                        if local.count >= limit { break }
                        pos = at + 1
                    }
                    (out + w).pointee = local
                }
            }
        }
        var all: [UInt32] = []
        all.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for p in parts { all.append(contentsOf: p) }
        return all
    }

    @inline(__always)
    private func equals(_ lit: [UInt16], at pos: Int) -> Bool {
        if pos < 0 || pos + lit.count > ix.searchCount { return false }
        let s = ix.search
        for i in 0..<lit.count where s[pos + i] != lit[i] { return false }
        return true
    }

    /// All matches of a pattern (literal or wildcard), sorted by start.
    func find(_ p: Pattern, ranges: [Range<Int>]) -> [Hit] {
        guard !p.isEmpty else { return [] }
        if p.lits.count == 1 {
            let n = UInt32(p.lits[0].count)
            return findLiteral(p.lits[0], ranges: ranges).map { Hit(start: $0, end: $0 + n) }
        }
        var k = 0
        for i in p.lits.indices where p.lits[i].count > p.lits[k].count { k = i }
        let anchors = findLiteral(p.lits[k], ranges: ranges, limit: maxHits * 4)
        let s = ix.search
        var hits = [Hit?](repeating: nil, count: anchors.count)
        hits.withUnsafeMutableBufferPointer { hp in
            let out = hp.baseAddress!
            DispatchQueue.concurrentPerform(iterations: (anchors.count + 4095) / 4096) { blk in
                let lo = blk * 4096, hi = min(lo + 4096, anchors.count)
                for ai in lo..<hi {
                    let a = Int(anchors[ai])
                    var end = a + p.lits[k].count
                    var ok = true
                    var i = k + 1
                    while i < p.lits.count && ok {
                        let g = p.gaps[i - 1]
                        var found = false
                        var d = 0
                        while d <= g.max {
                            if d > 0 && (end + d - 1 >= ix.searchCount || s[end + d - 1] == 0) { break }
                            if d >= g.min && equals(p.lits[i], at: end + d) {
                                end = end + d + p.lits[i].count; found = true; break
                            }
                            d += 1
                        }
                        ok = found
                        i += 1
                    }
                    var start = a
                    i = k - 1
                    while i >= 0 && ok {
                        let g = p.gaps[i]
                        var found = false
                        var d = 0
                        while d <= g.max {
                            if d > 0 && (start - d < 0 || s[start - d] == 0) { break }
                            if d >= g.min && equals(p.lits[i], at: start - d - p.lits[i].count) {
                                start = start - d - p.lits[i].count; found = true; break
                            }
                            d += 1
                        }
                        ok = found
                        i -= 1
                    }
                    if ok { (out + ai).pointee = Hit(start: UInt32(start), end: UInt32(end)) }
                }
            }
        }
        var res = hits.compactMap { $0 }
        res.sort { $0.start < $1.start }
        return res
    }

    // MARK: keyword

    func keyword(_ query: String, scope: [Bool]?, maxStar: Int) -> SearchResult {
        var r = SearchResult()
        let p = Pattern.compile(query, maxStar: maxStar)
        var hits = find(p, ranges: ranges(scope: scope))
        if hits.count > maxHits { hits.removeLast(hits.count - maxHits); r.truncated = true }
        r.hits = hits
        return r
    }

    // MARK: proximity

    /// Finds places where every term occurs, with at most `distance` other
    /// characters between them in total. `ordered` requires the query order.
    func proximity(terms: [String], distance: Int, ordered: Bool, scope: [Bool]?, maxStar: Int) -> SearchResult {
        var r = SearchResult()
        let pats = terms.map { Pattern.compile($0, maxStar: maxStar) }.filter { !$0.isEmpty }
        guard pats.count >= 2 else {
            if let p = pats.first { r.hits = find(p, ranges: ranges(scope: scope)) }
            return r
        }
        let rg = ranges(scope: scope)
        let lists = pats.map { find($0, ranges: rg) }
        let k = lists.count
        r.termCount = k
        if lists.contains(where: { $0.isEmpty }) { return r }
        var ptr = [Int](repeating: 0, count: k)
        var lastKey: (UInt32, UInt32) = (UInt32.max, UInt32.max)
        let s = ix.search
        outer: while true {
            var minI = 0
            var minStart = UInt32.max, maxEnd: UInt32 = 0, total: UInt32 = 0
            for i in 0..<k {
                let h = lists[i][ptr[i]]
                if h.start < minStart { minStart = h.start; minI = i }
                if h.end > maxEnd { maxEnd = h.end }
                total += h.end - h.start
            }
            let span = maxEnd - minStart
            if span <= total + UInt32(distance) {
                var ok = true
                // terms must not overlap each other
                var spans = (0..<k).map { (lists[$0][ptr[$0]].start, lists[$0][ptr[$0]].end) }
                if ordered {
                    for i in 1..<k where spans[i].0 < spans[i - 1].1 { ok = false }
                } else {
                    let sorted = spans.sorted { $0.0 < $1.0 }
                    for i in 1..<k where sorted[i].0 < sorted[i - 1].1 { ok = false }
                }
                if ok {
                    // stay inside one text
                    var q = Int(minStart)
                    while q < Int(maxEnd) { if s[q] == 0 { ok = false; break }; q += 1 }
                }
                if ok && !(lastKey.0 == minStart && lastKey.1 == maxEnd) {
                    lastKey = (minStart, maxEnd)
                    let subIndex = Int32(r.subSpans.count / (2 * k))
                    if !ordered { spans.sort { $0.0 < $1.0 } }
                    for sp in spans { r.subSpans.append(sp.0); r.subSpans.append(sp.1) }
                    r.hits.append(Hit(start: minStart, end: maxEnd, sub: subIndex))
                    if r.hits.count >= maxHits { r.truncated = true; break outer }
                }
            }
            ptr[minI] += 1
            if ptr[minI] >= lists[minI].count { break }
        }
        return r
    }
}

// MARK: - Scope filters

struct ScopeFilter: Equatable {
    var slr: Set<String>? = nil     // work ids from an SLR file
    var title = ""
    var author = ""
    var era = ""
    var only: Int? = nil            // a single text (index), e.g. the one open in the reader

    var isUnrestricted: Bool {
        slr == nil && title.trimmingCharacters(in: .whitespaces).isEmpty
            && author.trimmingCharacters(in: .whitespaces).isEmpty && era.isEmpty && only == nil
    }
}

func slrMatches(_ entries: Set<String>, id: String) -> Bool {
    if entries.contains(id) { return true }
    var base = Substring(id)
    while let l = base.last, l.isLetter, base.count > 1 { base = base.dropLast() }
    return base.count != id.count && entries.contains(String(base))
}

/// Title field also accepts text numbers: "T0001", "T01n0001", "1509".
func titleMatches(_ t: TextInfo, _ q: String) -> Bool {
    if q.isEmpty { return true }
    for term in q.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" }) {
        let s = String(term)
        let lower = s.lowercased()
        var ok = t.title.contains(s) || t.id.lowercased().contains(lower)
        if !ok {
            let digits = lower.drop { $0.isLetter }
            let letters = lower.prefix { $0.isLetter }
            if !digits.isEmpty, digits.allSatisfy({ $0.isNumber || $0.isLetter }) {
                var num = String(digits)
                while num.prefix(while: { $0.isNumber }).count < 4 { num = "0" + num }
                ok = t.no.lowercased() == num && (letters.isEmpty || t.canon.lowercased() == letters)
            }
        }
        if !ok { return false }
    }
    return true
}

func scopeMask(_ texts: [TextInfo], _ f: ScopeFilter) -> [Bool]? {
    if f.isUnrestricted { return nil }
    let title = f.title.trimmingCharacters(in: .whitespaces)
    let authorTerms = f.author.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" }).map(String.init)
    if let o = f.only { return texts.indices.map { $0 == o } }
    return texts.map { t in
        if let s = f.slr, !slrMatches(s, id: t.id) { return false }
        if !f.era.isEmpty && t.era != f.era { return false }
        for a in authorTerms where !t.author.contains(a) { return false }
        return titleMatches(t, title)
    }
}

// MARK: - SLR files (CBReader "limited search" ranges)

struct SLRFile: Identifiable, Hashable {
    var name: String
    var url: URL
    var ids: [String]
    var id: String { url.path }
}

func parseSLR(_ url: URL) -> SLRFile? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    var section = ""
    var ids: [String] = []
    for raw in text.split(whereSeparator: { $0.isNewline }) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") && line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
        guard section == "BuleiSingle" || section == "SutraSingle" else { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { ids.append(normalizeWorkId(v)) }
    }
    return SLRFile(name: url.deletingPathExtension().lastPathComponent, url: url, ids: ids)
}

func loadSLRFiles(_ dir: URL) -> [SLRFile] {
    let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return items.filter { $0.pathExtension.lowercased() == "slr" }
        .compactMap(parseSLR)
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// "X33n633" -> "X33n0633", "T1n1" -> "T01n0001"; leaves anything unexpected alone.
func normalizeWorkId(_ raw: String) -> String {
    let canon = raw.prefix { $0.isLetter }
    let rest = raw.dropFirst(canon.count)
    let parts = rest.split(separator: "n", maxSplits: 1, omittingEmptySubsequences: false)
    guard !canon.isEmpty, parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isNumber }) else { return raw }
    var vol = String(parts[0])
    while vol.count < 2 { vol = "0" + vol }
    var num = String(parts[1])
    while num.prefix(while: { $0.isNumber }).count < 4 { num = "0" + num }
    return "\(canon)\(vol)n\(num)"
}
