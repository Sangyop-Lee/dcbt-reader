import Foundation

/// A reference to a place in the Taishō (T) or Xuzangjing (X), as scholars write it:
///
///     T 2145: 55.63b20–22          T. 2059 [L] 358a11–14        T. 2039, 49: 998b19–999c10
///     T 45, no. 1853, p. 42a23     T 1853.45:26a19              T55, 61b9-10
///     T55n2145_p0063b20            T2145_.55.0063b20 (SAT)      CBETA 2025.R1, T30, no. 1579, p. 517b6-17
///     X 30, no. 600, p. 8b12       X. 1523 [LXXVII] 353b13      大正藏55冊63頁中 · 大正五五・六三中 · 대정장 55권 63쪽 중
///
/// The order of volume and text number differs between conventions, so numbers
/// that carry no label are kept as they come and settled against the library.
struct CanonRef {
    var canon: Character = "T"
    var vol: Int? = nil
    var no: Int? = nil
    var noSuffix = ""               // "a", "b" … as in T02n0128a
    var loose: [Int] = []           // numbers whose role (volume or text number) is not stated
    var page: Int? = nil
    var col: Character? = nil
    var line: Int? = nil
    var endPage: Int? = nil
    var endCol: Character? = nil
    var endLine: Int? = nil
    var juan: Int? = nil            // fascicle of the text: "juan 14", "卷十四", "14권"
    /// "vol. 14", "14卷" and "14권" can mean a volume of the canon or a fascicle of the text;
    /// the number is kept in `vol` and settled against the library.
    var volMayBeJuan = false
}

struct CanonLocation {
    var textIndex: Int
    var line: Int                   // global line index; -1 = start of the text
    var endLine: Int
    var exact: Bool                 // false: the page or line asked for is not there, nearest shown
    var juan: Int? = nil            // open at this fascicle (its number, not its position)
}

private func rx(_ p: String, _ s: String, options: NSRegularExpression.Options = []) -> [String?]? {
    guard let re = try? NSRegularExpression(pattern: p, options: options) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
}

private func rxRange(_ p: String, _ s: String, options: NSRegularExpression.Options = []) -> NSRange? {
    guard let re = try? NSRegularExpression(pattern: p, options: options) else { return nil }
    return re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))?.range
}

private func roman(_ s: String) -> Int? {
    let v: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100]
    var total = 0, prev = 0
    for ch in s.reversed() {
        guard let x = v[ch] else { return nil }
        if x < prev { total -= x } else { total += x; prev = x }
    }
    return total > 0 && total <= 100 ? total : nil
}

/// 二五 → 25, 二十五 → 25, 十 → 10; other characters are left alone.
private func arabicFromKanji(_ s: String) -> String {
    let d: [Character: Character] = ["〇": "0", "零": "0", "○": "0", "一": "1", "二": "2", "三": "3", "四": "4",
                                     "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"]
    let chars = Array(s)
    var out = ""
    for (i, ch) in chars.enumerated() {
        if let x = d[ch] { out.append(x); continue }
        if ch == "十" || ch == "百" {
            let before = i > 0 && d[chars[i - 1]] != nil
            let after = i + 1 < chars.count && d[chars[i + 1]] != nil
            if ch == "十" {
                if !before { out.append("1") }
                if !after { out.append("0") }
            } else if !after {
                out.append("00")
            } else if i + 2 < chars.count, chars[i + 2] != "十", d[chars[i + 2]] == nil {
                out.append("0")         // 一百五 → 105
            }
            continue
        }
        out.append(ch)
    }
    return out
}

private func column(_ s: String?) -> Character? {
    guard let c = s?.first else { return nil }
    switch c {
    case "a", "上", "상": return "a"
    case "b", "中", "중": return "b"
    case "c", "下", "하": return "c"
    default: return nil
    }
}

/// Reads a citation; nil if the text does not look like one (it is then searched as usual).
func parseCanonRef(_ input: String) -> CanonRef? {
    // a copied passage may be pasted whole, with its variant notes on the lines after it
    var s = input.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    s = String(s.prefix { !$0.isNewline })
    if s.count < 2 || s.count > 600 { return nil }
    for dash in ["–", "—", "‒", "−", "~", "～", "〜"] { s = s.replacingOccurrences(of: dash, with: "-") }
    // "(CBETA 2025.R1, T30, no. 1579, p. 517b6-17)"
    if let r = rxRange("^[\\(\\[（]?\\s*cbeta[^,，]*[,，]\\s*", s, options: .caseInsensitive) { s = (s as NSString).substring(from: r.length) }
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: "()[]（）〔〕《》『』「」〈〉【】 .。,，"))
    // A whole footnote may be pasted, with the title in front:
    // 《大方廣佛華嚴經》，CBETA, T10, no. 279, p. 299b16 · Da Tang xiyu ji 9, T 2087, 51.946c4
    // Start reading where the canon is named.
    let named = "大正新[脩修]大[藏蔵]|大正大[藏蔵]|大正[藏蔵]|대정신수대장경|대정장|卍[新纂大日本]*[續続][藏蔵]|新纂[續続][藏蔵]|속장경|taish[oō]|dazheng\\s*zang|xuzangjing"
    if rx("^(?:" + named + "|大正|대정|[續続][藏蔵]|xzj|[tx]\\.?\\s?[0-9\\[])", s, options: .caseInsensitive) == nil {
        if let r = rxRange("(?:" + named + ")|(?<![A-Za-z0-9])[TX]\\.?\\s?(?=[0-9]|no\\.?\\s?[0-9])", s, options: .caseInsensitive), r.location > 0 {
            s = (s as NSString).substring(from: r.location)
            if let c = rxRange("^cbeta[^,，]*[,，]\\s*", s, options: .caseInsensitive) { s = (s as NSString).substring(from: c.length) }
        }
    }

    var ref = CanonRef()
    let names: [(String, Character, Bool)] = [      // pattern, canon, bare (a single letter: needs care)
        ("^taish[oō]\\s*(shinsh[uū]\\s*daiz[oō]ky[oō]|tripi[tṭ]aka|canon|z[oō])?|^dazheng\\s*(xinxiu\\s*dazang\\s*jing|zang(jing)?)?", "T", false),
        ("^大正新[脩修]大[藏蔵][經经経]|^大正大[藏蔵][經经経]|^大正[藏蔵][經经経]?|^大正|^대정신수대장경|^대정장|^대정", "T", false),
        ("^xuzangjing|^xu\\s*zang\\s*jing|^wan\\s*xu\\s*zang(\\s*jing)?|^shinsan\\s*(dai\\s*nihon\\s*)?zokuz[oō]ky[oō]|^xzj|^卍[新纂大日本]*[續続][藏蔵][經经経]?|^新纂[續続][藏蔵][經经経]?|^[續続][藏蔵][經经経]?|^卍[續続]|^신찬속장경|^속장경|^만속장경?", "X", false),
        ("^t", "T", true), ("^x", "X", true),
    ]
    var rest: String? = nil
    for (p, c, bare) in names {
        guard let r = rxRange(p, s, options: .caseInsensitive) else { continue }
        let tail = (s as NSString).substring(from: r.length)
        if bare {
            // "T", "T.", then straight to a number, "no.", "vol." or a bracketed roman numeral
            guard rx("^\\.?\\s*(no\\.?|n\\.|nos?\\.|vol\\.?|#|第|\\[)?\\s*[0-9IVXL\\[]", tail, options: .caseInsensitive) != nil,
                  rx("^\\.?\\s*[A-HJ-KM-UWYZa-hj-kmp-uwyz]{2}", tail) == nil else { continue }
        }
        ref.canon = c
        rest = tail
        break
    }
    guard var r = rest else { return nil }
    r = arabicFromKanji(r)
    guard r.contains(where: { $0.isNumber }) || rx("[IVXL]", r) != nil else { return nil }

    // --- CBETA line heads: 55n2145_p0063b20, 02n0128a, 55n2145, and the status bar's "55n2145, p. 63b20"
    if let m = rx("^\\s*(\\d{1,3})n(\\d{1,4})([a-zA-Z])?(?:[_,\\s]*(?:pp?\\.?)?\\s*(\\d{1,4})([abc])(\\d{1,2})?)?(.*)$", r) {
        ref.vol = Int(m[1]!); ref.no = Int(m[2]!); ref.noSuffix = (m[3] ?? "").lowercased()
        if let p = m[4] { ref.page = Int(p); ref.col = column(m[5]); ref.line = m[6].flatMap { Int($0) } }
        parseRangeEnd(m[7] ?? "", into: &ref)
        return ref
    }
    // --- SAT: 2145_.55.0063b20
    if let m = rx("^\\s*(\\d{1,4})([a-zA-Z])?_\\.?(\\d{1,3})\\.(\\d{1,4})([abc])(\\d{1,2})?(.*)$", r) {
        ref.no = Int(m[1]!); ref.noSuffix = (m[2] ?? "").lowercased(); ref.vol = Int(m[3]!)
        ref.page = Int(m[4]!); ref.col = column(m[5]); ref.line = m[6].flatMap { Int($0) }
        parseRangeEnd(m[7] ?? "", into: &ref)
        return ref
    }

    // --- volume as a roman numeral: "T. 2059 [L] 358a11"
    if let m = rx("[\\[\\(]\\s*([IVXLC]+)\\s*[\\]\\)]", r) ?? rx("(?<![A-Za-z0-9])([IVXL]+)(?![A-Za-z0-9])", r), let v = roman(m[1]!) {
        ref.vol = v
        r = r.replacingOccurrences(of: m[0]!, with: " ")
    }
    r = r.lowercased()

    // --- page, column, line: "63b20", "63 b 20", "63, b20" (CBETA's own form), "63頁中", "63쪽 중", "356a 12"
    var head = r
    if let range = rxRange("(\\d{1,4})\\s*(?:頁|页|쪽|面|면)?\\s*[.,]?\\s*([abc上中下상중하])\\s*(?:欄|栏|段|단)?\\s*(\\d{1,2})?\\s*(?:行|행)?(?![a-z0-9])", r),
       let m = rx("(\\d{1,4})\\s*(?:頁|页|쪽|面|면)?\\s*[.,]?\\s*([abc上中下상중하])\\s*(?:欄|栏|段|단)?\\s*(\\d{1,2})?\\s*(?:行|행)?(?![a-z0-9])", r) {
        ref.page = Int(m[1]!); ref.col = column(m[2]); ref.line = m[3].flatMap { Int($0) }
        head = (r as NSString).substring(to: range.location)
        parseRangeEnd((r as NSString).substring(from: range.location + range.length), into: &ref)
    } else if let range = rxRange("(?:pp?\\.?|頁|页|쪽)\\s*(\\d{1,4})|(\\d{1,4})\\s*(?:頁|页|쪽|면)", r),
              let m = rx("(?:pp?\\.?|頁|页|쪽)\\s*(\\d{1,4})|(\\d{1,4})\\s*(?:頁|页|쪽|면)", r) {
        // a page with no column
        ref.page = Int(m[1] ?? m[2] ?? "")
        head = (r as NSString).substring(to: range.location)
    }

    // --- the numbers before the page: volume and text number, labelled or not
    guard let re = try? NSRegularExpression(pattern: "(nos?\\.?|n\\.|nr\\.?|#|經號|经号|vol(?:ume)?\\.?|v\\.|juan|j\\.|fasc(?:icle)?\\.?|scroll|卷第|卷|巻第|巻|권|冊|册|第|제)?\\s*(\\d{1,4})([a-z](?![a-z]))?\\s*(冊|册|卷(?!\\s*第|\\s*\\d)|巻(?!\\s*第|\\s*\\d)|권(?!\\s*\\d)|책|號|号|번|經|経|经)?") else { return nil }
    let ns = head as NSString
    for m in re.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
        func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        guard let n = Int(g(2) ?? "") else { continue }
        let pre = g(1) ?? "", post = g(4) ?? ""
        if pre.hasPrefix("n") || pre == "#" || pre.contains("號") || pre.contains("号") || ["號", "号", "번", "經", "経", "经"].contains(post) {
            ref.no = n; ref.noSuffix = g(3) ?? ""
        } else if pre == "冊" || pre == "册" {
            ref.vol = n
        } else if pre.hasPrefix("j") || pre.hasPrefix("fasc") || pre == "scroll" || pre.hasPrefix("卷") || pre.hasPrefix("巻") || pre == "권" {
            ref.juan = n
        } else if pre.hasPrefix("v") || ["冊", "册", "卷", "巻", "권", "책"].contains(post) {
            ref.vol = n
            // a 冊 or 책 is always a volume; "vol.", 卷 and 권 are also used for fascicles
            if pre.hasPrefix("v") || post == "卷" || post == "巻" || post == "권" { ref.volMayBeJuan = true }
        } else if let suffix = g(3), !suffix.isEmpty {
            ref.no = n; ref.noSuffix = suffix          // "T 128a"
        } else {
            ref.loose.append(n)
        }
    }
    if ref.vol == nil && ref.no == nil && ref.loose.isEmpty && ref.page == nil { return nil }
    // with a page, a 卷 is a volume of the canon: 《大正藏》卷9，頁465下
    if let j = ref.juan, ref.page != nil, ref.vol == nil { ref.vol = j; ref.juan = nil }
    // "T 2145 juan 14": the remaining number is the text number
    if ref.juan != nil, ref.no == nil, ref.vol == nil, ref.loose.count == 1 { ref.no = ref.loose[0]; ref.loose = [] }
    if ref.loose.count > 2 { return nil }
    return ref
}

/// "-22", "-b4", "-999c10" after the starting place.
private func parseRangeEnd(_ tail: String, into ref: inout CanonRef) {
    let t = tail.lowercased()
    if let m = rx("^\\s*-\\s*(\\d{1,4})\\s*([abc上中下])\\s*(\\d{1,2})?", t) {
        ref.endPage = Int(m[1]!); ref.endCol = column(m[2]); ref.endLine = m[3].flatMap { Int($0) }
    } else if let m = rx("^\\s*-\\s*([abc上中下])\\s*(\\d{1,2})?", t) {
        ref.endPage = ref.page; ref.endCol = column(m[1]); ref.endLine = m[2].flatMap { Int($0) }
    } else if let m = rx("^\\s*-\\s*(\\d{1,2})(?![0-9a-z])", t), ref.line != nil {
        ref.endPage = ref.page; ref.endCol = ref.col; ref.endLine = Int(m[1]!)
    }
}

extension CorpusIndex {
    /// (volume, text number, suffix) from an id such as "T55n2145" or "T02n0128a".
    private func idParts(_ id: String) -> (canon: Character, vol: Int, no: Int, suffix: String)? {
        guard let c = id.first, let n = id.firstIndex(of: "n") else { return nil }
        let volDigits = id[id.index(after: id.startIndex)..<n]
        let tail = id[id.index(after: n)...]
        let digits = tail.prefix { $0.isNumber }
        guard let v = Int(volDigits), let no = Int(digits) else { return nil }
        return (c, v, no, tail.dropFirst(digits.count).lowercased())
    }

    private func lbnKey(_ page: Int, _ col: Character?, _ line: Int?) -> String {
        String(format: "%04d", page) + String(col ?? "a") + String(format: "%02d", line ?? 1)
    }

    /// First line of a text at or after the place asked for; `exact` tells whether that page (and column) exists there.
    private func find(in ti: Int, page: Int, col: Character?, line: Int?) -> (line: Int, exact: Bool)? {
        let t = texts[ti]
        if t.lineCount == 0 { return nil }
        let key = lbnKey(page, col, line)
        let pagePrefix = String(key.prefix(col == nil ? 4 : 5))
        var best: Int? = nil
        for li in t.firstLine..<(t.firstLine + t.lineCount) {
            let s = unpackLbn(lines[li].lbn)
            if s.count >= 7 && s >= key { best = li; break }
        }
        guard let li = best else { return nil }
        return (li, unpackLbn(lines[li].lbn).hasPrefix(pagePrefix))
    }

    /// Settles a citation against the library. Unlabelled numbers are tried both
    /// as "volume, text number" and "text number, volume"; the reading that names
    /// an existing text containing the page wins.
    func locate(_ ref: CanonRef) -> CanonLocation? {
        var found = locatePlace(ref)
        if found == nil, ref.page != nil {
            // nothing fits as volume + text number: take whichever number works as a volume holding that page
            for n in ([ref.vol] + ref.loose.map { Optional($0) } + [ref.no]).compactMap({ $0 }) {
                var alone = ref
                alone.vol = n; alone.no = nil; alone.loose = []; alone.noSuffix = ""
                if let loc = locatePlace(alone), loc.exact { found = loc; break }
            }
        }
        if ref.page == nil {
            if let j = ref.juan, found != nil {
                found?.juan = j
            } else if ref.volMayBeJuan, found == nil || found?.exact == false, let j = ref.vol {
                // "T2145 vol 14", "T2145 14권": no volume 14 holds text 2145, so 14 is the fascicle
                var asJuan = ref
                asJuan.vol = nil
                asJuan.volMayBeJuan = false
                if asJuan.no == nil, asJuan.loose.count == 1 { asJuan.no = asJuan.loose[0]; asJuan.loose = [] }
                if asJuan.no != nil, var loc = locatePlace(asJuan), loc.exact {
                    loc.juan = j
                    found = loc
                }
            }
        }
        return found
    }

    private func locatePlace(_ ref: CanonRef) -> CanonLocation? {
        var tries: [(vol: Int?, no: Int?)] = []
        switch (ref.vol, ref.no, ref.loose.count) {
        case (_, _, 0): tries = [(ref.vol, ref.no)]
        case (nil, nil, 2): tries = [(ref.loose[0], ref.loose[1]), (ref.loose[1], ref.loose[0])]
        case (nil, nil, 1):
            // one number: with a page it is usually the volume (T55, 61b9); alone it is the text number (T 2145)
            tries = ref.page != nil ? [(ref.loose[0], nil), (nil, ref.loose[0])] : [(nil, ref.loose[0]), (ref.loose[0], nil)]
        case (let v?, nil, _): tries = [(v, ref.loose[0])]
        case (nil, let n?, _): tries = [(ref.loose[0], n)]
        default: tries = [(ref.vol, ref.no)]
        }
        var fallback: CanonLocation? = nil
        for (vol, no) in tries {
            var cands: [Int] = []
            for (i, t) in texts.enumerated() {
                guard let p = idParts(t.id), p.canon == ref.canon else { continue }
                if let v = vol, p.vol != v { continue }
                if let n = no {
                    if p.no != n { continue }
                    if !ref.noSuffix.isEmpty && p.suffix != ref.noSuffix { continue }
                } else if vol == nil { continue }
                cands.append(i)
            }
            if cands.isEmpty { continue }
            guard let page = ref.page else {
                if no != nil { return CanonLocation(textIndex: cands[0], line: -1, endLine: -1, exact: true) }
                continue
            }
            for ti in cands {
                guard let f = find(in: ti, page: page, col: ref.col, line: ref.line) else { continue }
                var end = f.line
                if let ep = ref.endPage, let e = find(in: ti, page: ep, col: ref.endCol ?? ref.col, line: ref.endLine ?? 99) {
                    end = max(f.line, e.exact || ref.endLine != nil ? e.line : e.line - 1)
                    if ref.endLine == nil { end = max(f.line, e.line - 1) }
                } else if ref.line == nil {
                    // a whole column or page: run to its end
                    let prefix = String(lbnKey(page, ref.col, 1).prefix(ref.col == nil ? 4 : 5))
                    let t = texts[ti]
                    while end + 1 < t.firstLine + t.lineCount, unpackLbn(lines[end + 1].lbn).hasPrefix(prefix) { end += 1 }
                }
                let loc = CanonLocation(textIndex: ti, line: f.line, endLine: end, exact: f.exact)
                if f.exact { return loc }
                if fallback == nil && no != nil { fallback = loc }
            }
            if fallback == nil, no != nil { fallback = CanonLocation(textIndex: cands[0], line: -1, endLine: -1, exact: false) }
        }
        return fallback
    }

    /// The citation of a line in CBETA's own form: "T55, no. 2145, p. 63b20".
    func citation(text ti: Int, line: Int) -> String {
        let t = texts[ti]
        guard let p = idParts(t.id) else { return t.id }
        var s = "\(p.canon)\(p.vol), no. \(p.no)\(p.suffix)"
        if line >= 0 { s += ", p. " + prettyLbn(unpackLbn(lines[line].lbn)) }
        return s
    }
}
