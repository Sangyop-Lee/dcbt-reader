import SwiftUI

// MARK: - Shared n-grams of two texts

/// For every searchable character of text `a`, the length (3…`maxN`, else 0) of the longest run of
/// characters around it that also occurs somewhere in text `b`. Punctuation and line breaks do not count.
///
/// Works up one length at a time: only the places of `a` whose n-gram is in `b` are tried at n + 1,
/// so the memory needed follows the shorter side even when the other is the 大般若經.
func sharedNgramLevels(_ ix: CorpusIndex, text a: Int, with b: Int, minN: Int = 3, maxN: Int = 8) -> [UInt8] {
    let ta = ix.texts[a], tb = ix.texts[b]
    let lenA = ta.searchEnd - ta.searchStart, lenB = tb.searchEnd - tb.searchStart
    var levels = [UInt8](repeating: 0, count: max(lenA, 0))
    guard lenA >= minN, lenB >= minN else { return levels }
    // titles, bylines and catalogue lines are not part of the comparison: their characters are
    // replaced by a mark that differs between the two texts, so that they match nothing
    let unitsA = ix.comparableUnits(text: a, blank: 0xFFFF), unitsB = ix.comparableUnits(text: b, blank: 0xFFFE)
    return unitsA.withUnsafeBufferPointer { pa in unitsB.withUnsafeBufferPointer { pb in
    let A = pa.baseAddress!, B = pb.baseAddress!
    @inline(__always) func key(_ p: UnsafePointer<UInt16>, _ n: Int) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for k in 0..<n { h = (h ^ UInt64(p[k])) &* 0x100000001b3 }
        return h
    }
    var alive = [Bool](repeating: true, count: lenA)
    var longest = [UInt8](repeating: 0, count: lenA)
    for n in minN...maxN {
        var wanted = Set<UInt64>()
        for i in 0..<lenA where alive[i] {
            if i + n <= lenA { wanted.insert(key(A + i, n)) } else { alive[i] = false }
        }
        if wanted.isEmpty || lenB < n { break }
        var found = Set<UInt64>()
        for j in 0...(lenB - n) {
            let h = key(B + j, n)
            if wanted.contains(h) { found.insert(h) }
        }
        if found.isEmpty { break }
        for i in 0..<lenA where alive[i] {
            if found.contains(key(A + i, n)) { longest[i] = UInt8(n) } else { alive[i] = false }
        }
    }
    for i in 0..<lenA where longest[i] > 0 {
        let n = longest[i]
        for c in i..<(i + Int(n)) where levels[c] < n { levels[c] = n }
    }
    return levels
    } }
}

extension CorpusIndex {
    /// The longest run of characters around global offset `k` of text `a` that also occurs in text `b`,
    /// as global offsets in `a`. `seed` is a length known to match there (from the comparison).
    func longestShared(around k: Int, in a: Int, with b: Int, seed: Int) -> Range<Int>? {
        let ta = texts[a], tb = texts[b]
        var best: Range<Int>? = nil
        guard seed >= 1, tb.searchEnd - tb.searchStart >= seed else { return nil }
        for i in max(k - seed + 1, ta.searchStart)...k where i + seed <= ta.searchEnd {
            let first = search[i]
            var j = tb.searchStart
            while j <= tb.searchEnd - seed {
                if search[j] == first {
                    var n = 1
                    while n < seed, search[j + n] == search[i + n] { n += 1 }
                    if n == seed {
                        // this occurrence: how far does it agree on either side?
                        var lo = i, hi = i + seed, jl = j, jh = j + seed
                        while lo > ta.searchStart, jl > tb.searchStart, search[lo - 1] == search[jl - 1], hi - lo < 120 { lo -= 1; jl -= 1 }
                        while hi < ta.searchEnd, jh < tb.searchEnd, search[hi] == search[jh], hi - lo < 120 { hi += 1; jh += 1 }
                        if hi - lo > (best?.count ?? 0) { best = lo..<hi }
                    }
                }
                j += 1
            }
        }
        return best
    }

    /// The searchable characters of a text, with those of its titles, bylines and catalogue lines replaced by `blank`.
    func comparableUnits(text ti: Int, blank: UInt16) -> [UInt16] {
        let t = texts[ti]
        var units = Array(UnsafeBufferPointer(start: search + t.searchStart, count: max(t.searchEnd - t.searchStart, 0)))
        let lastLine = t.firstLine + t.lineCount - 1
        guard lastLine >= t.firstLine else { return units }
        for (from, to) in skips(text: ti) {
            // count searchable units from the start of the line the header begins on
            var lo = t.firstLine, hi = lastLine
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if Int(lines[mid].dispStart) <= from { lo = mid } else { hi = mid - 1 }
            }
            var s = Int(lines[lo].searchStart) - t.searchStart
            var d = Int(lines[lo].dispStart)
            while d < min(to, t.dispEnd) {
                let u = display[d]
                var v = UInt32(u), width = 1
                if u >= 0xD800 && u <= 0xDBFF && d + 1 < t.dispEnd {
                    v = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(display[d + 1]) - 0xDC00)
                    width = 2
                }
                if isSearchScalar(v) {
                    if d >= from { for k in s..<min(s + width, units.count) where k >= 0 { units[k] = blank } }
                    s += width
                }
                d += width
            }
        }
        return units
    }

    /// Where the units `search[from..<from+count]` first occur in text `ti` (a global offset), if they do.
    func firstOccurrence(of from: Int, count: Int, in ti: Int) -> Int? {
        let t = texts[ti]
        guard count > 0, t.searchEnd - t.searchStart >= count else { return nil }
        let first = search[from]
        var j = t.searchStart
        while j <= t.searchEnd - count {
            if search[j] == first {
                var k = 1
                while k < count, search[j + k] == search[from + k] { k += 1 }
                if k == count { return j }
            }
            j += 1
        }
        return nil
    }
}

// MARK: - Comparing the text being read with another

extension AppState {
    /// Starts comparing the text being read with text `other`, or stops when `other` is nil.
    func compare(with other: Int?) {
        showComparePicker = false
        guard other == nil || other != readerText else { return }
        compareOther = other
        prepareComparison(redraw: true)
    }

    /// Finds the shared passages of the pair now in the reader: from the last few pairs kept, or worked
    /// out in the background and drawn when ready. `redraw` when the reader is not about to draw anyway.
    func prepareComparison(redraw: Bool) {
        compareGeneration += 1
        let gen = compareGeneration
        compareLevels = nil
        comparing = false
        defer { if redraw, rendered != nil { render(keepPlace: true) } }
        guard let ix = index, let a = readerText, let b = compareOther, a != b else { return }
        if let c = compareCache.first(where: { $0.a == a && $0.b == b }) { compareLevels = c.levels; return }
        comparing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let levels = sharedNgramLevels(ix, text: a, with: b)
            DispatchQueue.main.async {
                self.compareCache.append((a, b, levels))
                if self.compareCache.count > 4 { self.compareCache.removeFirst() }
                guard gen == self.compareGeneration else { return }
                self.compareLevels = levels
                self.comparing = false
                let shared = levels.reduce(0) { $0 + ($1 >= UInt8(self.ngramMin) ? 1 : 0) }
                self.status = "\(shared) of \(levels.count) characters of \(ix.texts[a].title) are in passages shared with \(ix.texts[b].title)."
                self.render(keepPlace: true)
            }
        }
    }

    /// The longest passage shared with the other text around the character at `loc` of the reader's
    /// text, if that character is in a highlighted run: where it is drawn, and its characters.
    func sharedPassage(at loc: Int) -> (attr: NSRange, text: String)? {
        guard let ix = index, let a = readerText, let b = compareOther, let levels = compareLevels, let r = rendered else { return nil }
        if let c = sharedHover, c.version == renderVersion, NSLocationInRange(loc, c.attr) { return (c.attr, c.text) }
        // the searchable character at or just before the pointer
        var k = -1
        for (i, l) in r.searchMap.enumerated() where l >= 0 {
            if Int(l) > loc { break }
            k = i
        }
        let rel = r.juanSearchStart + k
        guard k >= 0, loc - Int(r.searchMap[k]) <= 2, rel < levels.count, Int(levels[rel]) >= ngramMin else { return nil }
        let start = ix.texts[a].searchStart
        guard let run = ix.longestShared(around: start + rel, in: a, with: b, seed: Int(levels[rel])),
              let attr = r.location(ofSearchRange: (run.lowerBound - start)..<(run.upperBound - start)) else { return nil }
        let text = String(utf16CodeUnits: ix.search + run.lowerBound, count: run.count)
        sharedHover = (renderVersion, attr, text)
        return (attr, text)
    }

    /// A click on a shared passage: look for it in the other text.
    func searchShared(at loc: Int) {
        guard let ix = index, let b = compareOther, let p = sharedPassage(at: loc) else { return }
        byMeaning = false; goToMode = false
        selectedSLR = ""; authorFilter = ""; eraFilter = ""; onlyCurrentText = false
        titleFilter = ix.texts[b].id
        query = p.text
        if !showResults { toggle(.results) }
        filtersChanged(rerun: false)
        runSearch()
    }

    func setNgramMin(_ n: Int) {
        ngramMin = min(max(n, 3), 8)
        UserDefaults.standard.set(ngramMin, forKey: "ngramMin")
        if compareLevels != nil { render(keepPlace: true) }
    }

    /// Puts the other text in the reader, at the passage it shares with the place being read,
    /// and compares in the other direction. Doing it again comes back.
    func swapComparison() {
        guard let ix = index, let a = readerText, let b = compareOther else { return }
        var target: Range<Int>? = nil          // global search offsets in b
        if let levels = compareLevels {
            let minN = UInt8(ngramMin)
            // from the line being read
            var start = 0
            if let p = currentPlace(), let li = ix.lineIndex(text: a, lbn: p.lbn) { start = Int(ix.lines[li].searchStart) - ix.texts[a].searchStart }
            // the shared passage at or after the place being read, else the one before it
            var s = (max(start, 0)..<levels.count).first { levels[$0] >= minN } ?? (0..<min(start, levels.count)).last { levels[$0] >= minN }
            if var k = s {
                while k > 0, levels[k - 1] > 0 { k -= 1 }
                s = k
                let from = ix.texts[a].searchStart + k
                var n = min(Int(levels[k]), levels.count - k)
                while n >= 3, target == nil {
                    if let j = ix.firstOccurrence(of: from, count: n, in: b) { target = j..<(j + n) }
                    n -= 1
                }
            }
        }
        compareOther = a
        let tb = ix.texts[b]
        if let t = target {
            openReader(text: b, juan: ix.juanIndex(at: t.lowerBound, text: b),
                       focus: (t.lowerBound - tb.searchStart)..<(t.upperBound - tb.searchStart), quiet: true)
        } else {
            openReader(text: b, juan: 0, focus: nil)
        }
    }
}

// MARK: - Controls

/// The compare button of the reader toolbar, and what it shows while two texts are being compared.
struct CompareBar: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let ix = state.index, let other = state.compareOther, other < ix.texts.count {
            HStack(spacing: 6) {
                Button { state.swapComparison() } label: {
                    Label(String(ix.texts[other].title.prefix(12)), systemImage: "arrow.left.arrow.right").lineLimit(1)
                }
                .fixedSize()
                .help("Go to \(ix.texts[other].title) (\(ix.texts[other].id)), at the passage it shares with this place; the same button there comes back")
                if state.comparing { ProgressView().controlSize(.small) }
                Picker("", selection: Binding(get: { state.ngramMin }, set: { state.setNgramMin($0) })) {
                    ForEach(3...8, id: \.self) { Text("\($0)+").tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("Shortest shared run of characters to highlight. Longer shared runs are highlighted more strongly.")
                Button { state.compare(with: nil) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Stop comparing")
            }
        } else {
            Button { state.showComparePicker = true } label: { Image(systemName: "rectangle.on.rectangle") }
                .help("Compare this text with another: passages of three or more characters that both have are highlighted")
        }
    }
}

/// Chooses the text to compare with.
struct ComparePicker: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare with…").font(.title3).bold()
            Text("Type part of a title or a number (地持, T1582, 1582). Passages of three to eight or more characters that the two texts share are highlighted in the text, the longer the stronger.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Title or number", text: $state.compareQuery)
            if let ix = state.index {
                let q = state.compareQuery.trimmingCharacters(in: .whitespaces).lowercased()
                let num = Int(q.drop { !$0.isNumber })
                let found = q.isEmpty ? [] : ix.texts.indices.filter { i in
                    let t = ix.texts[i]
                    return (t.title.contains(q) || t.id.lowercased().contains(q)
                        || (num != nil && Int(t.no.prefix { $0.isNumber }) == num && (q.first?.isNumber == true || t.canon.lowercased() == String(q.prefix(1)))))
                }
                List(found.prefix(200), id: \.self) { i in
                    Button { state.compare(with: i) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ix.texts[i].title)
                            Text(i == state.readerText ? "\(ix.texts[i].id) · the text you are reading; choose the one to compare it with"
                                                       : "\(ix.texts[i].id)\(ix.texts[i].author.isEmpty ? "" : " · " + ix.texts[i].author)")
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(i == state.readerText)
                }
                .frame(height: 260)
            }
            HStack { Spacer(); Button("Cancel") { state.showComparePicker = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 460)
    }
}
