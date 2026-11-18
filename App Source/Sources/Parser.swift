import Foundation

// MARK: - Parsed model

/// One reading in a critical-apparatus entry.
struct AppReading {
    var wits: [String]      // witness labels, e.g. "【宋】"
    var text: String        // empty = the witness omits the passage
}

/// One critical-apparatus entry (`<app>` in the `<back>` of a CBETA file).
struct AppEntry {
    var from: String        // anchor id where the lemma starts
    var to: String          // anchor id where the lemma ends
    var lem: String
    var lemWits: [String]
    var rdgs: [AppReading]
}

struct TokStyle: OptionSet {
    let rawValue: UInt8
    static let note = TokStyle(rawValue: 1)         // interlinear note
    static let head = TokStyle(rawValue: 2)         // heading / juan title
    static let byline = TokStyle(rawValue: 4)
    static let front = TokStyle(rawValue: 8)         // catalogue line such as "No. 235 [Nos. 220(9), 236-239]"
    static let gaiji = TokStyle(rawValue: 64)        // one character outside Unicode; see ParsedDoc.gaiji
    static let displayOnly = TokStyle(rawValue: 128) // shown but never searched
}

enum Tok {
    case text(String, TokStyle)
    case lb(String)         // line beginning, n = "0001a02"
    case juan(Int)
    case para               // block boundary
    case anchor(String)     // xml:id of an anchor (apparatus begin/end)
    case section(String, Int)   // a chapter heading as the text prints it, and its level (1 outermost); "" = nothing printed at this level; level 0 = a fascicle's 品之餘 heading, standing in for the one it continues
}

struct ParsedDoc {
    var id = ""             // file basename, e.g. "T01n0001"
    var title = ""
    var author = ""
    var extent = ""
    var toks: [Tok] = []
    var apps: [AppEntry] = []
    var witnessLabels: [String] = []   // labels that actually occur in the apparatus
    var origWitness: String? = nil     // label of the printed edition itself: 【大】, 【卍續】 …
    /// Token index -> CBETA id (CB…, SD-…, RJ-…) and description of a character that has no Unicode;
    /// the token's text is the stand-in (normalised form, transliteration or composition).
    var gaiji: [Int: (id: String, note: String)] = [:]
}

// MARK: - Character classes

/// True for scalars that take part in searching (ideographs, letters, digits).
/// Punctuation, spaces and private-use characters are skipped, so that a query
/// matches regardless of the modern punctuation CBETA adds.
@inline(__always)
func isSearchScalar(_ v: UInt32) -> Bool {
    if v >= 0x4E00 && v <= 0x9FFF { return true }
    if v < 0x80 {
        return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
    }
    if v >= 0x3400 && v <= 0x4DBF { return true }
    if v >= 0x20000 && v <= 0x323AF { return true }
    if v >= 0xF900 && v <= 0xFAFF { return true }
    if v == 0x3007 { return true }
    if v >= 0x3040 && v <= 0x30FF { return v != 0x30FB && v != 0x3099 && v != 0x309A && v != 0x30A0 }
    if v >= 0xAC00 && v <= 0xD7A3 { return true }
    if v >= 0xC0 && v <= 0x24F { return v != 0xD7 && v != 0xF7 }
    if v >= 0x1E00 && v <= 0x1EFF { return true }
    return false
}

/// Appends the searchable UTF-16 units of `s` to `out` (ASCII lower-cased).
func appendSearchUnits(_ s: String, to out: inout [UInt16]) {
    for u in s.unicodeScalars {
        var v = u.value
        guard isSearchScalar(v) else { continue }
        if v >= 0x41 && v <= 0x5A { v += 32 }
        if v < 0x10000 {
            out.append(UInt16(v))
        } else {
            let x = v - 0x10000
            out.append(UInt16(0xD800 + (x >> 10)))
            out.append(UInt16(0xDC00 + (x & 0x3FF)))
        }
    }
}

func searchUnits(_ s: String) -> [UInt16] {
    var a: [UInt16] = []
    appendSearchUnits(s, to: &a)
    return a
}

func countSearchUnits(_ s: String) -> Int {
    var n = 0
    for u in s.unicodeScalars where isSearchScalar(u.value) { n += u.value < 0x10000 ? 1 : 2 }
    return n
}

// MARK: - Parser

/// SAX parser for CBETA TEI P5 files. Produces a flat token stream for the body
/// and the list of apparatus entries from the back matter.
final class CBETAParser: NSObject, XMLParserDelegate {
    private var doc = ParsedDoc()
    private let canonEd: String

    private enum Section { case none, header, body, back }
    private var section = Section.none

    private var skipDepth = 0
    private var styleStack: [TokStyle] = [[]]
    private var buf = ""
    private var bufStyle: TokStyle = []

    // header capture
    private var capture: String? = nil
    private var captureKind = ""
    private var witnessById: [String: String] = [:]
    private var curWitId = ""
    private var curCharId = ""
    private var curLocalName = ""
    private var charUnicode: [String: String] = [:]
    private var charNormal: [String: String] = [:]
    private var charCompose: [String: String] = [:]
    private var charRoman: [String: String] = [:]

    // gaiji
    private var gRef: String? = nil
    private var gContent = ""
    private var gaijiOutsideUnicode = false

    // apparatus
    private var curApp: AppEntry? = nil
    private var rdgTarget = 0      // 0 none, 1 lem, 2 rdg
    private var rdgText = ""
    private var rdgWits: [String] = []
    private var usedWits = Set<String>()
    private var witOrder: [String] = []
    private var muluText: String? = nil
    private var muluLevel = 1
    /// Table-of-contents entries waiting for the printed heading that follows them.
    private var pendingMulu: [(level: Int, name: String)] = []
    private var headText: String? = nil
    private var headContinues = false
    private var lastHeadTok: Int? = nil
    private var textSinceHead = true

    private static let blockTags: Set<String> = [
        "p", "lg", "l", "head", "byline", "item", "cb:juan", "entry", "row", "cb:div",
        "list", "table", "cb:docNumber", "trailer", "sp", "cb:dialog", "cb:jl_title", "cb:event",
    ]

    init(canonEd: String) { self.canonEd = canonEd }

    static func parse(url: URL) -> ParsedDoc? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        let canon = String(base.prefix { $0.isLetter })
        let d = CBETAParser(canonEd: canon)
        d.doc.id = base
        let p = XMLParser(data: data)
        p.delegate = d
        p.shouldProcessNamespaces = false
        p.shouldResolveExternalEntities = false
        p.parse()
        d.flush()
        d.doc.witnessLabels = d.witOrder
        d.doc.origWitness = d.witnessById["wit.orig"]
        return d.doc
    }

    // MARK: token helpers

    private func flush() {
        if !buf.isEmpty {
            doc.toks.append(.text(buf, bufStyle))
            buf = ""
        }
    }

    /// The headings waiting in `pendingMulu` become section marks. The printed heading (when there is one)
    /// stands for the innermost entry, and the outer entries it follows directly are covered by it:
    /// 初方便處 ▸ 戒品 under the one heading 菩薩地持方便處戒品第十.
    private func settleSections(head: String?) {
        guard !pendingMulu.isEmpty else { return }
        let pend = pendingMulu
        pendingMulu = []
        let printed = head?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 本地分 ▸ [heading 本地分中五識身相應地第一] ▸ 五識身相應地: a heading printed between an outer entry and
        // the inner one that follows it at once is the inner one's heading
        var moved = ""
        if printed.isEmpty, !textSinceHead, let k = lastHeadTok, case .section(let h, let lv) = doc.toks[k], lv < pend[0].level {
            flush()
            doc.toks[k] = .section("", lv)
            moved = h
        }
        lastHeadTok = nil
        for (k, m) in pend.enumerated() {
            // an entry with no printed heading is CBETA's own outline (章, 節 …), not the text's: it leaves no name
            emit(.section(!moved.isEmpty ? (k == 0 ? moved : "") : (k == pend.count - 1 ? printed : ""), m.level))
        }
        if !printed.isEmpty { lastHeadTok = doc.toks.count - 1; textSinceHead = false }
    }

    private func emitText(_ s: String, extra: TokStyle = []) {
        let st = styleStack[styleStack.count - 1].union(extra)
        if headText != nil {
            if !st.contains(.note) && !st.contains(.displayOnly) { headText! += s }
        } else if !pendingMulu.isEmpty, !st.contains(.displayOnly) {
            settleSections(head: nil)       // text began with no heading printed
            textSinceHead = true
        } else if !st.contains(.displayOnly) {
            textSinceHead = true
        }
        if st != bufStyle { flush(); bufStyle = st }
        buf += s
    }

    private func emit(_ t: Tok) {
        flush()
        doc.toks.append(t)
    }

    private func labels(_ wit: String?) -> [String] {
        guard let wit = wit else { return [] }
        var out: [String] = []
        for w in wit.split(separator: " ") {
            let id = w.hasPrefix("#") ? String(w.dropFirst()) : String(w)
            let label = witnessById[id] ?? id
            out.append(label)
            if usedWits.insert(label).inserted { witOrder.append(label) }
        }
        return out
    }

    private func resolveGaiji() -> (String, Bool) {
        let ref = gRef ?? ""
        if let f = gContent.unicodeScalars.first {
            let v = f.value
            let pua = (v >= 0xE000 && v <= 0xF8FF) || v >= 0xF0000
            if !pua { return (gContent, false) }
        }
        if let u = charUnicode[ref], let v = UInt32(u.dropFirst(2), radix: 16), let sc = Unicode.Scalar(v) {
            return (String(Character(sc)), false)
        }
        gaijiOutsideUnicode = true
        if let n = charNormal[ref], !n.isEmpty { return (n, false) }
        if let r = charRoman[ref], !r.isEmpty { return (r, true) }
        if let c = charCompose[ref], !c.isEmpty { return (c, true) }
        return ("\u{25A1}", true)
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes at: [String: String] = [:]) {
        switch section {
        case .none:
            if el == "teiHeader" { section = .header }
            else if el == "body" { section = .body }
            else if el == "back" { flush(); section = .back }
        case .header:
            switch el {
            case "title":
                if at["level"] == "m" && doc.title.isEmpty { capture = ""; captureKind = "title" }
            case "author":
                if doc.author.isEmpty { capture = ""; captureKind = "author" }
            case "extent":
                capture = ""; captureKind = "extent"
            case "witness":
                curWitId = at["xml:id"] ?? ""; capture = ""; captureKind = "witness"
            case "char":
                curCharId = at["xml:id"] ?? ""
            case "localName":
                capture = ""; captureKind = "localName"
            case "value":
                capture = ""; captureKind = "value"
            case "mapping":
                if at["type"] == "unicode" { capture = ""; captureKind = "mapping" }
            default: break
            }
        case .body:
            startBody(el, at)
        case .back:
            startBack(el, at)
        }
    }

    private func startBody(_ el: String, _ at: [String: String]) {
        if skipDepth > 0 {
            skipDepth += 1
            return
        }
        switch el {
        case "lb":
            if at["ed"] == canonEd, let n = at["n"] { emit(.lb(n)) }
        case "anchor":
            if let id = at["xml:id"], !id.hasPrefix("nkr_") { emit(.anchor(id)) }
        case "milestone":
            if at["unit"] == "juan", let n = at["n"], let v = Int(n) { emit(.juan(v)) }
        case "g":
            gRef = (at["ref"] ?? "").replacingOccurrences(of: "#", with: "")
            gContent = ""
        case "note":
            let place = at["place"] ?? ""
            if at["type"] == nil && (place.contains("inline") || place.contains("interlinear")) {
                styleStack.append(styleStack[styleStack.count - 1].union(.note))
                emitText("(", extra: .displayOnly)
            } else {
                skipDepth = 1
            }
        case "cb:mulu":
            // chapters (品, 分, 會 …) are remembered for citations; the 卷 entries are not chapters
            if let ty = at["type"], ty != "卷" { muluText = ""; muluLevel = Int(at["level"] ?? "") ?? 1 }
            skipDepth = 1
        case "figure", "graphic", "rdg":
            skipDepth = 1
        case "cb:t":
            if let lang = at["xml:lang"], !lang.hasPrefix("zh") { skipDepth = 1 }
        case "caesura":
            emitText("\u{3000}", extra: .displayOnly)
        case "space":
            if let q = at["quantity"], let n = Int(q), n > 0 {
                emitText(String(repeating: "\u{3000}", count: min(n, 8)), extra: .displayOnly)
            }
        case "head", "cb:jhead":
            if el == "head" { emit(.para); if headText == nil { headText = ""; headContinues = false } }
            else if at["type"] == "pin", headText == nil { headText = ""; headContinues = true }   // 戒品之餘 at the head of a fascicle
            styleStack.append(styleStack[styleStack.count - 1].union(.head))
        case "cb:docNumber":
            emit(.para)
            styleStack.append(styleStack[styleStack.count - 1].union(.front))
        case "byline", "cb:jl_byline":
            if el == "byline" { emit(.para) }
            styleStack.append(styleStack[styleStack.count - 1].union(.byline))
        default:
            if CBETAParser.blockTags.contains(el) && at["cb:place"] != "inline" && at["place"] != "inline" {
                emit(.para)
            }
        }
    }

    private func startBack(_ el: String, _ at: [String: String]) {
        if skipDepth > 0 { skipDepth += 1; return }
        switch el {
        case "app":
            let f = (at["from"] ?? "").replacingOccurrences(of: "#", with: "")
            let t = (at["to"] ?? "").replacingOccurrences(of: "#", with: "")
            curApp = AppEntry(from: f, to: t, lem: "", lemWits: [], rdgs: [])
        case "lem":
            if curApp != nil { rdgTarget = 1; rdgText = ""; rdgWits = labels(at["wit"]) }
        case "rdg":
            guard curApp != nil else { break }
            rdgTarget = 2; rdgText = ""; rdgWits = labels(at["wit"])
            // An editor's conjecture ("教＝散？"), which CBETA labels 【考偽-大】: not a witness's reading.
            if at["type"] == "correctionRemark" {
                rdgWits = rdgWits.map { "【考偽-" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "【】")) + "】" }
            }
        case "note":
            let place = at["place"] ?? ""
            if rdgTarget != 0 && at["type"] == nil && place.contains("inline") {
                rdgText += "("
            } else {
                skipDepth = 1
            }
        case "g":
            gRef = (at["ref"] ?? "").replacingOccurrences(of: "#", with: "")
            gContent = ""
        case "cb:t":
            if let lang = at["xml:lang"], !lang.hasPrefix("zh") { skipDepth = 1 }
        case "figure", "graphic", "cb:mulu":
            skipDepth = 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) {
        if capture != nil { capture! += s; return }
        switch section {
        case .body:
            if skipDepth > 0 { if muluText != nil { muluText! += s }; return }
            if gRef != nil { gContent += s; return }
            appendClean(s) { emitText($0) }
        case .back:
            if skipDepth > 0 || rdgTarget == 0 { return }
            if gRef != nil { gContent += s; return }
            appendClean(s) { rdgText += $0 }
        default: break
        }
    }

    @inline(__always)
    private func appendClean(_ s: String, _ sink: (String) -> Void) {
        var needs = false
        for u in s.utf8 where u == 10 || u == 13 || u == 9 { needs = true; break }
        if !needs { sink(s); return }
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value != 10 && $0.value != 13 && $0.value != 9 }))
        if !cleaned.isEmpty { sink(cleaned) }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        switch section {
        case .header:
            if el == "teiHeader" { section = .none; return }
            guard let c = capture else { return }
            let v = c.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (el, captureKind) {
            case ("title", "title"): doc.title = v
            case ("author", "author"): doc.author = v
            case ("extent", "extent"): doc.extent = v
            case ("witness", "witness"): witnessById[curWitId] = v
            case ("localName", "localName"): curLocalName = v
            case ("value", "value"):
                if curLocalName == "normalized form" { charNormal[curCharId] = v }
                else if curLocalName == "composition" { charCompose[curCharId] = v }
                else if curLocalName == "Romanized form in Unicode transcription" { charRoman[curCharId] = v }
            case ("mapping", "mapping"): charUnicode[curCharId] = v
            default: return
            }
            capture = nil
        case .body:
            if el == "body" { settleSections(head: nil); flush(); section = .none; return }
            if skipDepth > 0 {
                skipDepth -= 1
                if skipDepth == 0, el == "cb:mulu", let m = muluText {
                    muluText = nil
                    // "10 戒品": CBETA's own numbering in front of the name is not the text's
                    var name = m.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let sp = name.firstIndex(of: " "), sp > name.startIndex, name[..<sp].allSatisfy({ $0.isNumber }) {
                        name = String(name[name.index(after: sp)...])
                    }
                    if !name.isEmpty { pendingMulu.append((muluLevel, name)) }
                }
                return
            }
            switch el {
            case "g":
                let ref = gRef ?? ""
                gaijiOutsideUnicode = false
                let (t, displayOnly) = resolveGaiji()
                gRef = nil
                if gaijiOutsideUnicode && !ref.isEmpty {
                    // its own token, so the reader can show CBETA's image of the character
                    flush()
                    let st = styleStack[styleStack.count - 1].union(displayOnly ? [.displayOnly, .gaiji] : .gaiji)
                    doc.toks.append(.text(t, st))
                    var note = ref
                    if let c = charCompose[ref], !c.isEmpty { note += " " + c }
                    if let n = charNormal[ref], !n.isEmpty { note += "（通用字 " + n + "）" }
                    if let r = charRoman[ref], !r.isEmpty { note += " " + r }
                    doc.gaiji[doc.toks.count - 1] = (ref, note)
                } else {
                    emitText(t, extra: displayOnly ? .displayOnly : [])
                }
            case "note":
                emitText(")", extra: .displayOnly)
                if styleStack.count > 1 { styleStack.removeLast() }
            case "cb:docNumber":
                if styleStack.count > 1 { styleStack.removeLast() }
                flush()
                emit(.para)
            case "head", "cb:jhead", "byline", "cb:jl_byline":
                if styleStack.count > 1 { styleStack.removeLast() }
                flush()
                if let h = headText, (el == "head") != headContinues, el == "head" || el == "cb:jhead" {
                    headText = nil
                    let printed = h.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !pendingMulu.isEmpty || !headContinues { settleSections(head: h) }
                    else if !printed.isEmpty { emit(.section(printed, 0)); lastHeadTok = doc.toks.count - 1; textSinceHead = false }
                }
                if el != "cb:jl_byline" { emit(.para) }
            case "p", "lg", "l", "item", "cb:juan", "entry", "row", "list", "table":
                emit(.para)
            default: break
            }
        case .back:
            if el == "back" { section = .none; return }
            if skipDepth > 0 { skipDepth -= 1; return }
            switch el {
            case "g":
                let (t, _) = resolveGaiji()
                gRef = nil
                if rdgTarget != 0 { rdgText += t }
            case "note":
                if rdgTarget != 0 { rdgText += ")" }
            case "lem":
                if rdgTarget == 1 { curApp?.lem = rdgText; curApp?.lemWits = rdgWits }
                rdgTarget = 0
            case "rdg":
                if rdgTarget == 2 { curApp?.rdgs.append(AppReading(wits: rdgWits, text: rdgText)) }
                rdgTarget = 0
            case "app":
                if let a = curApp, !a.from.isEmpty { doc.apps.append(a) }
                curApp = nil
            default: break
            }
        case .none:
            break
        }
    }
}

// MARK: - Era extraction

/// Dynasties / polities with an approximate starting year, used to sort the era menu.
let eraStartYear: [String: Int] = [
    "後漢": 25, "東漢": 25, "漢": 25, "曹魏": 220, "魏": 220, "吳": 222, "西晉": 265, "晉": 265, "晉世": 265,
    "前涼": 301, "東晉": 317, "前秦": 351, "符秦": 351, "苻秦": 351, "後秦": 384, "姚秦": 384,
    "西秦": 385, "乞伏秦": 385, "北涼": 397, "元魏": 386, "後魏": 386, "北魏": 386, "劉宋": 420,
    "蕭齊": 479, "南齊": 479, "齊": 479, "梁": 502, "東魏": 534, "西魏": 535, "高齊": 550, "北齊": 550,
    "陳": 557, "北周": 557, "宇文周": 557, "周": 557, "隋": 581, "唐": 618, "新羅": 668, "大周": 690,
    "南唐": 937, "後唐": 923, "後晉": 936, "後周": 951, "吳越": 907, "遼": 916, "高麗": 918,
    "宋": 960, "北宋": 960, "西夏": 1038, "金": 1115, "南宋": 1127, "元": 1271, "明": 1368,
    "朝鮮": 1392, "清": 1644, "民國": 1912, "日本": 3000, "失譯": 4000,
]

/// Extracts the era from a CBETA author byline such as "馬鳴菩薩造　後秦 鳩摩羅什譯".
func eraFromByline(_ byline: String) -> String {
    let segs = byline.split(separator: "\u{3000}")
    for seg in segs.reversed() {
        let parts = seg.split(separator: " ", maxSplits: 1)
        if parts.count == 2 {
            let e = String(parts[0])
            if e.count <= 4 { return e }
        }
    }
    if byline.contains("失譯") { return "失譯" }
    return ""
}
