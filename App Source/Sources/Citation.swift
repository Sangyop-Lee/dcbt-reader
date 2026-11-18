import AppKit

// MARK: - What a copied passage carries

/// One apparatus entry inside a copied passage, read against the printed edition.
struct CiteNote {
    var label: String               // "36", "A1", "＊": the footnote's own number
    var base: String                // what the printed edition has
    var readings: [AppReading]      // what the others have (CBETA's correction included)
}

/// A passage of the printed edition (Taishō, Xuzangjing …) with everything a citation may use.
struct CitationSource {
    enum Segment { case text(String), mark(Int) }
    var canon = "T"
    var volume = 0
    var number = ""                 // "1581", "128a"
    var title = ""
    var juan = 1
    var sections: [String] = []     // chapter headings as printed, outermost first
    var segments: [Segment] = []
    var notes: [CiteNote] = []
    var start = "0001a01"           // page, column, line: where the passage starts and ends
    var end = "0001a01"

    /// The example shown in the settings when nothing is selected.
    static let sample = CitationSource(
        canon: "T", volume: 30, number: "1581", title: "菩薩地持經", juan: 5, sections: ["菩薩地持方便處戒品之餘"],
        segments: [.text("若"), .mark(0), .text("彼"), .mark(1), .text("聞已向惡人說"), .mark(2), .text("破壞正法。")],
        notes: [CiteNote(label: "36", base: "彼", readings: [AppReading(wits: ["【宮】"], text: "知")]),
                CiteNote(label: "37", base: "聞", readings: [AppReading(wits: ["【宋】", "【元】", "【明】"], text: "知")]),
                CiteNote(label: "38", base: "破壞正法", readings: [AppReading(wits: ["【聖】", "【知】"], text: "")])],
        start: "0914a29", end: "0914b01")
}

/// "beg0914036" → "36", "beg0914a01" → "A1", a repeated note (＊) → "＊".
private func noteLabel(_ anchor: String) -> String {
    let id = anchor.hasPrefix("beg") ? String(anchor.dropFirst(3)) : anchor
    if id.hasPrefix("_") { return "＊" }
    let tail = id.dropFirst(4)
    if id.count == 7, id.allSatisfy({ $0.isNumber }), let n = Int(tail) { return String(n) }
    if id.count == 7, let c = tail.first, c.isLetter, let n = Int(tail.dropFirst()) { return c.uppercased() + String(n) }
    return "CB"
}

/// Reads the selected part of a rendered juan back from the tokens, as the printed edition has it:
/// where CBETA corrected the text, the original reading is restored and the correction becomes a note.
func citationSource(rendered r: RenderedJuan, selection sel: NSRange, text t: TextInfo, juan: Int) -> CitationSource? {
    guard let doc = r.doc, sel.length > 0 else { return nil }
    let lo = sel.location, hi = sel.location + sel.length
    guard let first = r.runs.first(where: { $0.loc + $0.len > lo && $0.loc < hi }),
          let last = r.runs.last(where: { $0.loc < hi && $0.loc + $0.len > lo }) else { return nil }
    let offA = first.whole ? 0 : max(lo - first.loc, 0)
    let offB = last.whole ? Int.max : min(hi - last.loc, last.len)

    var src = CitationSource(canon: t.canon, volume: t.vol, title: t.title, juan: juan)
    let digits = t.no.prefix { $0.isNumber }
    src.number = (Int(digits).map(String.init) ?? String(digits)) + t.no.dropFirst(digits.count)

    // a passage that starts at a lemma also takes the anchor in front of it
    var from = first.tok
    if offA == 0 {
        scan: while from > 0 {
            switch doc.toks[from - 1] {
            case .anchor, .lb, .para: from -= 1
            default: break scan
            }
        }
    }
    // the headings the passage stands under: the nearest one, then each shallower level above it
    var lbn = ""
    var chain: [(level: Int, name: String, old: Bool)] = []    // old: stands before the fascicle's 品之餘 heading
    var cont: String? = nil
    /// "戒品之餘" at the head of a fascicle stands in for the heading it continues (the one it shares its
    /// opening with), and whatever was open beneath that heading has ended.
    func continued(_ c: String) {
        var best: Int? = nil, bestLen = -1
        for (k, e) in chain.enumerated() where e.old && !e.name.isEmpty {
            let n = e.name.commonPrefix(with: c).count
            if n >= bestLen { best = k; bestLen = n }
        }
        guard let k = best else { chain.append((1, c, false)); return }
        let lv = chain[k].level
        chain[k] = (lv, c, false)
        chain.removeAll { $0.old && $0.level > lv }
    }
    var i = from - 1
    while i >= 0, lbn.isEmpty || (chain.first?.level ?? Int.max) > 1 {
        switch doc.toks[i] {
        case .lb(let n): if lbn.isEmpty { lbn = n }
        case .section(let name, let level):
            if name.isEmpty && level == 0 { break }
            if level == 0 {
                if cont == nil, !chain.contains(where: { !$0.name.isEmpty }) { cont = name }
            } else if level < (chain.first?.level ?? Int.max) {
                chain.insert((level, name, cont != nil), at: 0)
            }
        default: break
        }
        i -= 1
    }
    if let c = cont { continued(c) }

    var byFrom: [String: [Int]] = [:]
    for (k, a) in doc.apps.enumerated() { byFrom[a.from, default: []].append(k) }
    var suppressUntil: String? = nil
    var started = false
    func add(_ s: String) {
        guard !s.isEmpty else { return }
        if !started { started = true; src.start = lbn }
        src.end = lbn
        src.segments.append(.text(s))
    }
    for ti in from...last.tok {
        switch doc.toks[ti] {
        case .lb(let n): lbn = n
        case .section(let name, let level):
            if started || (name.isEmpty && level == 0) { break }
            if level == 0 {
                for k in chain.indices { chain[k].old = true }
                continued(name)
            } else { chain = chain.filter { $0.level < level } + [(level, name, false)] }
        case .anchor(let id):
            for ai in byFrom[id] ?? [] {
                let e = doc.apps[ai]
                var note = CiteNote(label: noteLabel(e.from), base: e.lem, readings: e.rdgs)
                src.segments.append(.mark(src.notes.count))
                if let o = doc.origWitness, !e.lemWits.contains(o), suppressUntil == nil,
                   let k = e.rdgs.firstIndex(where: { $0.wits.contains(o) }) {
                    // CBETA changed the text here: put the printed reading back
                    note.base = e.rdgs[k].text
                    note.readings.remove(at: k)
                    note.readings.insert(AppReading(wits: e.lemWits, text: e.lem), at: 0)
                    add(e.rdgs[k].text)
                    if e.to != e.from { suppressUntil = e.to }
                }
                src.notes.append(note)
            }
            if suppressUntil == id { suppressUntil = nil }
        case .text(let str, _):
            if suppressUntil != nil { continue }
            let ns = str as NSString
            let a = ti == first.tok ? min(offA, ns.length) : 0
            let b = ti == last.tok ? min(offB, ns.length) : ns.length
            if b > a { add(ns.substring(with: NSRange(location: a, length: b - a))) }
        default: break
        }
    }
    src.sections = chain.map { $0.name }.filter { !$0.isEmpty }
    return started ? src : nil
}

// MARK: - The format

enum CiteKind: String, Codable, CaseIterable {
    case title, juan, section, sectionNumber, quote, canon, number, volume, page, column, line, notes, literal

    var name: String {
        switch self {
        case .title: return "Title"
        case .juan: return "Fascicle"
        case .section: return "Chapter"
        case .sectionNumber: return "Chapter no."
        case .quote: return "Quoted text"
        case .canon: return "Canon"
        case .number: return "Text no."
        case .volume: return "Volume"
        case .page: return "Page"
        case .column: return "Column"
        case .line: return "Line"
        case .notes: return "Variant notes"
        case .literal: return "Text"
        }
    }

    /// The ways the element can be written; the first is the default.
    var styles: [String] {
        switch self {
        case .canon: return ["T / X", "T. / X.", "Taishō / Xuzangjing", "大正藏 / 卍續藏", "大正 / 續藏", "대정장 / 속장경"]
        case .column: return ["a b c", "上 中 下", "상 중 하"]
                case .juan, .number, .sectionNumber: return ["5", "五"]
        case .volume: return ["5", "五", "V (Roman numeral)"]
        case .page, .line: return ["5", "五", "0005 (as CBETA's line heads)"]
        default: return []
        }
    }
}

struct CitePiece: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: CiteKind
    var before = ""         // printed only when the element has a value
    var after = ""
    var style = 0           // index into the kind's styles; one past the last = the user's own wording
    var text = ""           // of a literal
    var custom: [String]? = nil     // own wording: canon [T, X], column [a, b, c]

    static func lit(_ s: String) -> CitePiece { CitePiece(kind: .literal, text: s) }
    static func el(_ k: CiteKind, _ before: String = "", _ after: String = "", style: Int = 0) -> CitePiece {
        CitePiece(kind: k, before: before, after: after, style: style)
    }
}

struct CiteFormat: Codable, Equatable {
    var pieces: [CitePiece]
    var dash = "–"
    var excluded: [String] = []     // editions left out of the variant notes

    static let presets: [(name: String, make: () -> CiteFormat)] = [
        ("T1581, 30:914a29–b1 (default)", {
            CiteFormat(pieces: [.el(.title, "『", "』"), .el(.juan, "卷"), .el(.section, "「", "」"), .lit("："), .el(.quote),
                                .lit(" ("), .el(.canon), .el(.number), .lit(", "), .el(.volume), .lit(":"), .el(.page),
                                .el(.column), .el(.line), .lit(")"), .el(.notes, "\n")])
        }),
        // The journal formats follow articles written for each journal; Buddhist Studies Review's is the rule in its
        // guidelines for contributors (April 2026).
        ("T'oung Pao: T. 1581: 30.914a29–b1", {
            CiteFormat(pieces: english([.el(.title, "", " "), .el(.juan, "", ", ")],
                                       .el(.canon, "", " ", style: 1), .el(.number), .lit(": "), .el(.volume), .lit("."),
                                       .el(.page), .el(.column), .el(.line)))
        }),
        ("Philosophy East and West: T 30, no. 1581, pp. 914a29–b1", {
            CiteFormat(pieces: english([.el(.title, "", ", ")],
                                       .el(.canon, "", " "), .el(.volume), .lit(", no. "), .el(.number), .lit(", "),
                                       .el(.page, "p. "), .el(.column), .el(.line)))
        }),
        ("JAOS: T 1581: 30.914a29–b1", {
            CiteFormat(pieces: english([.el(.title, "", ", ")],
                                       .el(.canon, "", " "), .el(.number), .lit(": "), .el(.volume), .lit("."),
                                       .el(.page), .el(.column), .el(.line)))
        }),
        ("The Eastern Buddhist: T no. 1581, 30: 914a29–b1", {
            CiteFormat(pieces: english([.el(.title, "", ", ")],
                                       .el(.canon, "", " no. "), .el(.number), .lit(", "), .el(.volume), .lit(": "),
                                       .el(.page), .el(.column), .el(.line)))
        }),
        ("Buddhist Studies Review: T1581 (30) 914a29–b1", {
            CiteFormat(pieces: english([.el(.title, "", ", ")],
                                       .el(.canon), .el(.number), .el(.volume, " (", ") "), .el(.page), .el(.column), .el(.line)))
        }),
        ("印度学仏教学研究：『…』：…（T30, 914a29–b1）", {
            CiteFormat(pieces: [.el(.title, "『", "』"), .lit("："), .el(.quote), .lit("（"), .el(.canon), .el(.volume), .lit(", "),
                                .el(.page), .el(.column), .el(.line), .lit("）"), .el(.notes, "\n")])
        }),
        ("中文：《大正藏》第30冊，頁914上29", {
            CiteFormat(pieces: [.el(.title, "《", "》"), .el(.juan, "卷"), .el(.section, "〈", "〉"), .lit("："), .el(.quote, "「", "」"),
                                .lit("（"), .el(.canon, "《", "》", style: 3), .el(.volume, "第", "冊"), .el(.number, "，第", "號"),
                                .el(.page, "，頁"), .el(.column, style: 1), .el(.line), .lit("）"), .el(.notes, "\n")])
        }),
        ("한국어: 『…』 권5, T30, 914a29", {
            CiteFormat(pieces: [.el(.title, "『", "』"), .el(.juan, " 권"), .el(.section, " 「", "」"), .lit(": "), .el(.quote, "“", "”"),
                                .lit(" ("), .el(.canon), .el(.volume), .lit(", "), .el(.page), .el(.column), .el(.line), .lit(")"),
                                .el(.notes, "\n")])
        }),
    ]

    static var standard: CiteFormat { presets[0].make() }

    /// The frame shared by the English-language journals: the passage, then title and place in parentheses.
    private static func english(_ lead: [CitePiece], _ place: CitePiece...) -> [CitePiece] {
        [.el(.quote), .lit(" (")] + lead + place + [.lit(")"), .el(.notes, "\n")]
    }
}

/// A format the user saved under a name.
struct NamedFormat: Codable, Identifiable {
    var name: String
    var format: CiteFormat
    var id: String { name }
}

extension CiteKind {
    /// What the user fills in to word an element their own way; empty for elements that are plain numbers.
    var customLabels: [String] {
        switch self {
        case .canon: return ["Taishō", "Xuzangjing"]
        case .column: return ["a", "b", "c"]
        default: return []
        }
    }
    var customDefaults: [String] {
        switch self {
        case .canon: return ["T", "X"]
        case .column: return ["a", "b", "c"]
        default: return []
        }
    }
}

// MARK: - Writing a citation out

private let kanjiDigits = Array("〇一二三四五六七八九")

/// 25 → 二十五 (a count) or 二五 (a page read digit by digit).
private func kanji(_ n: Int, positional: Bool) -> String {
    if positional || n <= 0 || n > 9999 { return String(String(n).compactMap { $0.wholeNumberValue.map { kanjiDigits[$0] } }) }
    var out = ""
    var rest = n
    for (unit, name) in [(1000, "千"), (100, "百"), (10, "十")] {
        let d = rest / unit
        rest %= unit
        if d == 0 { continue }
        if !(d == 1 && unit == 10 && out.isEmpty) { out.append(kanjiDigits[d]) }
        out += name
    }
    if rest > 0 { out.append(kanjiDigits[rest]) }
    return out
}

private func roman(_ n: Int) -> String {
    var rest = n, out = ""
    for (v, r) in [(100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
        while rest >= v { out += r; rest -= v }
    }
    return out
}

private func numeral(_ n: Int, style: Int, width: Int = 0, positional: Bool = true) -> String {
    switch style {
    case 1: return kanji(n, positional: positional)
    case 2: return String(format: "%0\(width)d", n)
    default: return String(n)
    }
}

extension CiteFormat {
    /// The variant notes of a passage that survive the choice of editions, with the witnesses kept.
    private func keptNotes(_ s: CitationSource) -> [Int: String] {
        guard pieces.contains(where: { $0.kind == .notes }) else { return [:] }
        let off = Set(excluded)
        var out: [Int: String] = [:]
        for (i, n) in s.notes.enumerated() {
            var parts: [String] = []
            for r in n.readings {
                let wits = r.wits.filter { !off.contains($0) }.joined()
                if wits.isEmpty { continue }
                if n.base.isEmpty { parts.append("＋\(r.text)\(wits)") }
                else if r.text.isEmpty { parts.append("〔\(n.base)〕－\(wits)") }
                else { parts.append("\(n.base)＝\(r.text)\(wits)") }
            }
            if !parts.isEmpty { out[i] = "[\(n.label)]" + parts.joined(separator: "，") + "。" }
        }
        return out
    }

    private func place(_ lbn: String) -> (page: String, col: String, line: String) {
        let c = Array(lbn)
        guard c.count >= 7 else { return (lbn, "", "") }
        return (String(c[0..<4]), String(c[4]), String(c[5...]))
    }

    private func value(_ p: CitePiece, _ s: CitationSource, at lbn: String, quote: String, notes: String) -> String? {
        let at = place(lbn)
        let own = p.style >= p.kind.styles.count ? p.custom : nil
        switch p.kind {
        case .literal: return p.text
        case .title: return s.title.isEmpty ? nil : s.title
        case .juan: return numeral(s.juan, style: p.style, positional: false)
        case .section:
            // every level, each in the piece's own brackets: 「…」「…」
            return s.sections.isEmpty ? nil : s.sections.joined(separator: p.after + p.before)
        case .sectionNumber:
            return nil      // no longer offered: the heading is copied as printed, number and all
        case .quote: return quote
        case .canon:
            if let c = own, c.count == 2, let k = ["T": 0, "X": 1][s.canon] { return c[k] }
            let names: [String: [String]] = ["T": ["T", "T.", "Taishō", "大正藏", "大正", "대정장"],
                                             "X": ["X", "X.", "Xuzangjing", "卍續藏", "續藏", "속장경"]]
            return names[s.canon].map { $0[min(p.style, $0.count - 1)] } ?? s.canon
        case .number:
            let digits = s.number.prefix { $0.isNumber }
            return (Int(digits).map { numeral($0, style: p.style) } ?? String(digits)) + s.number.dropFirst(digits.count)
        case .volume: return p.style == 2 ? roman(s.volume) : numeral(s.volume, style: p.style)
        case .page: return Int(at.page).map { numeral($0, style: p.style, width: 4) } ?? at.page
        case .column:
            let k = ["a": 0, "b": 1, "c": 2][at.col]
            if let c = own, c.count == 3, let k = k { return c[k] }
            let sets = [["a", "b", "c"], ["上", "中", "下"], ["상", "중", "하"]]
            return k.map { sets[min(p.style, 2)][$0] } ?? at.col
        case .line: return Int(at.line).map { numeral($0, style: p.style, width: 2) } ?? at.line
        case .notes: return notes.isEmpty ? nil : notes
        }
    }

    func render(_ s: CitationSource) -> String {
        let kept = keptNotes(s)
        var quote = ""
        for seg in s.segments {
            switch seg {
            case .text(let t): quote += t
            case .mark(let i): if kept[i] != nil { quote += "[\(s.notes[i].label)]" }
            }
        }
        quote = quote.replacingOccurrences(of: "\n", with: "")
        let notes = s.notes.indices.compactMap { kept[$0] }.joined()

        func write(_ p: CitePiece, at lbn: String) -> String {
            guard let v = value(p, s, at: lbn, quote: quote, notes: notes) else { return "" }
            return p.kind == .literal ? v : p.before + v + p.after
        }
        // the place is everything from the first to the last of page, column and line;
        // a passage that runs on repeats it after the dash from the first part that differs
        let level: [CiteKind: Int] = [.page: 0, .column: 1, .line: 2]
        let a = place(s.start), b = place(s.end)
        let differs = a.page != b.page ? 0 : a.col != b.col ? 1 : a.line != b.line ? 2 : 3
        let firstPlace = pieces.firstIndex { level[$0.kind] != nil }
        let lastPlace = pieces.lastIndex { level[$0.kind] != nil }
        var out = ""
        for (i, var p) in pieces.enumerated() {
            // "p." becomes "pp." when the passage runs over more than one line
            if p.kind == .page, differs < 3, p.before.hasSuffix("p. "), !p.before.hasSuffix("pp. ") {
                p.before = String(p.before.dropLast(3)) + "pp. "
            }
            out += write(p, at: s.start)
            if i == lastPlace, let f = firstPlace, differs < 3,
               let from = pieces[f...i].firstIndex(where: { (level[$0.kind] ?? -1) >= differs }) {
                // the end of the passage is written without the label in front of it: "p. 31c25–32a2"
                var endRun = Array(pieces[from...i])
                endRun[0].before = ""
                out += dash + endRun.map { write($0, at: s.end) }.joined()
            }
        }
        return out
    }
}

// MARK: - Settings kept between launches

final class CitationSettings: ObservableObject {
    @Published var format: CiteFormat { didSet { if format != oldValue { save() } } }
    @Published var selected: UUID? = nil
    @Published var saved: [NamedFormat] = [] { didSet { if let d = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(d, forKey: "citationFormats") } } }
    @Published var name = ""            // the name the format in use was saved under, or is about to be
    var dragging: UUID? = nil
    var draggingNew: CiteKind? = nil

    init() {
        if let d = UserDefaults.standard.data(forKey: "citationFormat"), let f = try? JSONDecoder().decode(CiteFormat.self, from: d) {
            format = f
            format.pieces.removeAll { $0.kind == .sectionNumber }     // from before headings were copied as printed
        } else {
            format = .standard
        }
        if let d = UserDefaults.standard.data(forKey: "citationFormats"), let s = try? JSONDecoder().decode([NamedFormat].self, from: d) {
            saved = s
            for i in saved.indices { saved[i].format.pieces.removeAll { $0.kind == .sectionNumber } }
        }
        name = UserDefaults.standard.string(forKey: "citationFormatName") ?? ""
    }

    /// Keeps the format in use under `name`, replacing one of that name.
    func saveAs() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        name = n
        if let i = saved.firstIndex(where: { $0.name == n }) { saved[i].format = format } else { saved.append(NamedFormat(name: n, format: format)) }
        UserDefaults.standard.set(n, forKey: "citationFormatName")
    }

    func use(_ f: CiteFormat, named n: String) {
        format = f
        name = n
        selected = nil
        UserDefaults.standard.set(n, forKey: "citationFormatName")
    }

    func delete(_ n: String) {
        saved.removeAll { $0.name == n }
        if name == n { name = "" }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(format) { UserDefaults.standard.set(d, forKey: "citationFormat") }
    }

    func index(of id: UUID?) -> Int? { format.pieces.firstIndex { $0.id == id } }

    func add(_ kind: CiteKind, at i: Int? = nil) -> UUID {
        let p = kind == .literal ? CitePiece.lit(", ") : CitePiece.el(kind, kind == .notes ? "\n" : "")
        format.pieces.insert(p, at: min(i ?? format.pieces.count, format.pieces.count))
        selected = p.id
        return p.id
    }

    func remove(_ id: UUID?) {
        format.pieces.removeAll { $0.id == id }
        if selected == id { selected = nil }
    }

    /// The dragged piece came over another piece (nil: the end of the row): it takes that place.
    func dragEntered(_ target: UUID?) {
        if let kind = draggingNew {
            draggingNew = nil
            dragging = add(kind, at: index(of: target))
            return
        }
        guard let d = dragging, d != target, let from = index(of: d) else { return }
        let piece = format.pieces[from]
        var p = format.pieces
        p.remove(at: from)
        let to = target.flatMap { t in p.firstIndex { $0.id == t } }.map { $0 >= from ? $0 + 1 : $0 } ?? p.count
        p.insert(piece, at: min(to, p.count))
        format.pieces = p
    }

    func move(_ id: UUID, by step: Int) {
        guard let i = index(of: id), format.pieces.indices.contains(i + step) else { return }
        format.pieces.swapAt(i, i + step)
    }

    func setExcluded(_ wit: String, _ off: Bool) {
        var e = format.excluded.filter { $0 != wit }
        if off { e.append(wit) }
        format.excluded = e
    }
}

extension AppState {
    /// The selected passage as the printed edition has it, with its place and variants.
    func selectedCitationSource() -> CitationSource? {
        guard let ix = index, let ti = readerText, let r = rendered else { return nil }
        let t = ix.texts[ti]
        let juan = readerJuan < t.juans.count ? t.juans[readerJuan].n : readerJuan + 1
        return citationSource(rendered: r, selection: selectionRange, text: t, juan: juan)
    }

    /// Puts the selected passage on the clipboard in the user's citation format.
    func copyCitation() {
        guard let s = selectedCitationSource() else { status = "Select a passage in the text to copy it with its citation."; return }
        let text = citation.format.render(s)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied with citation: " + String(text.replacingOccurrences(of: "\n", with: " ").prefix(80))
    }
}
