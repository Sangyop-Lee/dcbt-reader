import Foundation
import AppKit

// The app ships without dictionaries. The user puts their own in the
// "Dictionaries" folder beside the app:
//   · StarDict: the files (.ifo, .idx, .dict or .dict.dz) or the archive they came in
//     (.tar.bz2, .tbz, .trz, .tar.gz, .zip, .7z, .bz2 …)
//   · Babylon: a .bgl file
// Each is prepared once, into the app's support folder, and the original is left alone.

/// One dictionary found in the Dictionaries folder.
struct DictionarySource: Identifiable, Hashable {
    enum Kind: String { case stardict, archive, babylon }
    var id: String              // path relative to the Dictionaries folder
    var url: URL
    var kind: Kind
    var kindLabel: String { kind == .babylon ? "Babylon" : kind == .archive ? "StarDict archive" : "StarDict" }
}

/// A dictionary ready for lookups: headword index in memory, entries read from disk.
final class LoadedDictionary {
    private var entries: [String: (UInt32, UInt32)] = [:]
    private var dict: Data
    let name: String
    let sourceId: String

    /// Reads a StarDict index: "headword \0 offset(4, big-endian) size(4, big-endian)" repeated.
    init?(idx idxURL: URL, dict dictURL: URL, sourceId: String) {
        guard let idx = try? Data(contentsOf: idxURL, options: .alwaysMapped),
              let d = try? Data(contentsOf: dictURL, options: .alwaysMapped) else { return nil }
        dict = d
        self.sourceId = sourceId
        var title = idxURL.deletingPathExtension().lastPathComponent
        let ifo = idxURL.deletingPathExtension().appendingPathExtension("ifo")
        if let s = try? String(contentsOf: ifo, encoding: .utf8),
           let line = s.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("bookname=") }) {
            title = String(line.dropFirst(9))
        }
        name = title
        entries.reserveCapacity(64_000)
        idx.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = p.count
            while i < n {
                var j = i
                while j < n, p[j] != 0 { j += 1 }
                guard j + 9 <= n else { break }
                let word = String(decoding: UnsafeBufferPointer(rebasing: p[i..<j]), as: UTF8.self)
                let off = UInt32(p[j + 1]) << 24 | UInt32(p[j + 2]) << 16 | UInt32(p[j + 3]) << 8 | UInt32(p[j + 4])
                let size = UInt32(p[j + 5]) << 24 | UInt32(p[j + 6]) << 16 | UInt32(p[j + 7]) << 8 | UInt32(p[j + 8])
                if entries[word] == nil { entries[word] = (off, size) }
                i = j + 9
            }
        }
        if entries.isEmpty { return nil }
    }

    var count: Int { entries.count }

    func lookup(_ word: String) -> String? {
        guard let (o, s) = entries[word], Int(o) + Int(s) <= dict.count else { return nil }
        return String(decoding: dict.subdata(in: Int(o)..<(Int(o) + Int(s))), as: UTF8.self)
    }
}

enum DictionaryInstaller {
    static let archiveExtensions: Set<String> = ["trz", "tbz", "tbz2", "bz2", "tgz", "gz", "tar", "txz", "xz", "zip", "7z", "rar"]

    private static func run(_ tool: String, _ args: [String], output: URL? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let o = output {
            FileManager.default.createFile(atPath: o.path, contents: nil)
            guard let h = FileHandle(forWritingAtPath: o.path) else { return false }
            p.standardOutput = h
        } else { p.standardOutput = FileHandle.nullDevice }
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        // gzip exits 2 for "trailing garbage ignored", which a Babylon file always has
        return p.terminationStatus == 0 || (tool.hasSuffix("gzip") && p.terminationStatus == 2)
    }

    private static var cacheRoot: URL { AppPaths.supportDir.appendingPathComponent("Dictionary cache", isDirectory: true) }

    private static func size(_ u: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Everything in the Dictionaries folder that looks like a dictionary.
    static func scan() -> [DictionarySource] {
        let fm = FileManager.default
        guard let dir = AppPaths.dictionariesDir,
              let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let base = dir.standardizedFileURL.path
        var out: [DictionarySource] = []
        for case let u as URL in en {
            if en.level > 3 { en.skipDescendants(); continue }
            let ext = u.pathExtension.lowercased()
            let name = u.lastPathComponent.lowercased()
            var rel = String(u.standardizedFileURL.path.dropFirst(base.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            if ext == "bgl" {
                out.append(DictionarySource(id: rel, url: u, kind: .babylon))
            } else if ext == "idx" {
                let b = u.deletingPathExtension()
                if fm.fileExists(atPath: b.appendingPathExtension("dict").path) || fm.fileExists(atPath: b.appendingPathExtension("dict.dz").path) {
                    out.append(DictionarySource(id: rel, url: u, kind: .stardict))
                }
            } else if archiveExtensions.contains(ext), !name.hasSuffix(".dict.dz") {
                out.append(DictionarySource(id: rel, url: u, kind: .archive))
            }
        }
        return out.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func findStarDict(in dir: URL) -> URL? {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let u as URL in en where u.pathExtension.lowercased() == "idx" {
            let b = u.deletingPathExtension()
            if FileManager.default.fileExists(atPath: b.appendingPathExtension("dict").path)
                || FileManager.default.fileExists(atPath: b.appendingPathExtension("dict.dz").path) { return u }
        }
        return nil
    }

    private static func findBabylon(in dir: URL) -> URL? {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let u as URL in en where u.pathExtension.lowercased() == "bgl" { return u }
        return nil
    }

    /// The .dict beside an .idx, unpacking .dict.dz (gzip) into `cache` once if that is all there is.
    private static func dictFile(for idx: URL, cache: URL, status: (String) -> Void) -> URL? {
        let fm = FileManager.default
        let b = idx.deletingPathExtension()
        let plain = b.appendingPathExtension("dict")
        if fm.fileExists(atPath: plain.path) { return plain }
        let dz = b.appendingPathExtension("dict.dz")
        guard fm.fileExists(atPath: dz.path) else { return nil }
        let out = cache.appendingPathComponent(b.lastPathComponent + ".unpacked.dict")
        if fm.fileExists(atPath: out.path), size(out) > 0 { return out }
        status("Unpacking \(b.lastPathComponent) (once)…")
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        guard run("/usr/bin/gzip", ["-dc", dz.path], output: out) else { try? fm.removeItem(at: out); return nil }
        return out
    }

    /// Gets a dictionary ready and returns its index and entry files.
    static func prepare(_ source: DictionarySource, status: (String) -> Void) -> (idx: URL, dict: URL)? {
        let fm = FileManager.default
        let cache = cacheRoot.appendingPathComponent(source.url.lastPathComponent + "-\(size(source.url))", isDirectory: true)
        switch source.kind {
        case .stardict:
            guard let d = dictFile(for: source.url, cache: cache, status: status) else { return nil }
            return (source.url, d)
        case .babylon:
            return convertBabylon(source.url, into: cache, status: status)
        case .archive:
            let unpacked = cache.appendingPathComponent("unpacked", isDirectory: true)
            if !fm.fileExists(atPath: unpacked.path) {
                status("Unpacking \(source.url.lastPathComponent) (once)…")
                try? fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
                // bsdtar recognises tar, bzip2, gzip, xz, zip and 7z by content, whatever the file is called
                guard run("/usr/bin/tar", ["-xf", source.url.path, "-C", unpacked.path]) else { try? fm.removeItem(at: unpacked); return nil }
            }
            if let idx = findStarDict(in: unpacked), let d = dictFile(for: idx, cache: cache, status: status) { return (idx, d) }
            if let bgl = findBabylon(in: unpacked) { return convertBabylon(bgl, into: cache, status: status) }
            return nil
        }
    }

    // MARK: Babylon (.bgl)

    /// A .bgl file is a short header followed by a gzip stream of blocks. Each block
    /// starts with a byte whose low half is its type and whose high half says how its
    /// length is written. Types 1, 7, 10 and 11 are entries: headword, definition and
    /// alternative headwords. Type 3 blocks carry the title and other information.
    /// The entries are written out once as a StarDict-style index and entry file.
    private static func convertBabylon(_ bgl: URL, into cache: URL, status: (String) -> Void) -> (idx: URL, dict: URL)? {
        let fm = FileManager.default
        let idxURL = cache.appendingPathComponent("converted.idx")
        let dictURL = cache.appendingPathComponent("converted.dict")
        if fm.fileExists(atPath: idxURL.path), fm.fileExists(atPath: dictURL.path), size(idxURL) > 0 { return (idxURL, dictURL) }
        status("Reading \(bgl.lastPathComponent) (once)…")
        guard let file = try? Data(contentsOf: bgl, options: .alwaysMapped), file.count > 8,
              file[file.startIndex] == 0x12, file[file.startIndex + 1] == 0x34 else { return nil }
        let off = Int(file[file.startIndex + 4]) << 8 | Int(file[file.startIndex + 5])
        guard off > 5, off < file.count else { return nil }
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let gz = cache.appendingPathComponent("stream.gz"), rawURL = cache.appendingPathComponent("stream.raw")
        defer { try? fm.removeItem(at: gz); try? fm.removeItem(at: rawURL) }
        guard (try? file.subdata(in: (file.startIndex + off)..<file.endIndex).write(to: gz)) != nil,
              run("/usr/bin/gzip", ["-dc", gz.path], output: rawURL),
              let raw = try? Data(contentsOf: rawURL, options: .alwaysMapped), !raw.isEmpty else { return nil }

        var title = bgl.deletingPathExtension().lastPathComponent
        var order: [String] = []
        var defs: [String: [Data]] = [:]
        var utf8 = true
        func text(_ d: Data) -> String {
            if let s = String(data: d, encoding: .utf8) { return s }
            utf8 = false
            return String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
        }
        raw.withUnsafeBytes { buf in
            let p = buf.bindMemory(to: UInt8.self)
            let n = p.count
            func num(_ at: Int, _ len: Int) -> Int {
                var v = 0
                var k = 0
                while k < len, at + k < n { v = v << 8 | Int(p[at + k]); k += 1 }
                return v
            }
            func bytes(_ at: Int, _ len: Int) -> Data {
                at >= 0 && len > 0 && at + len <= n ? Data(UnsafeBufferPointer(rebasing: p[at..<(at + len)])) : Data()
            }
            var i = 0
            while i < n {
                let head = p[i]; i += 1
                let type = Int(head & 0x0F), hi = Int(head >> 4)
                var len = hi - 4
                if hi < 4 { len = num(i, hi + 1); i += hi + 1 }
                let start = i, end = min(i + max(len, 0), n)
                i = end
                if type == 3, end - start > 2, num(start, 2) == 0x01 {
                    let t = text(bytes(start + 2, end - start - 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { title = t }
                } else if type == 1 || type == 7 || type == 10 || type == 11 {
                    var q = start
                    var heads: [Data] = []
                    var def = Data()
                    if type == 11 {
                        let hl = num(q, 5); q += 5
                        heads.append(bytes(q, hl)); q += hl
                        let alts = num(q, 4); q += 4
                        var a = 0
                        while a < alts, q + 4 <= end { let al = num(q, 4); q += 4; heads.append(bytes(q, al)); q += al; a += 1 }
                        let dl = num(q, 4); q += 4
                        def = bytes(q, min(dl, end - q))
                    } else {
                        let hl = Int(p[q]); q += 1
                        heads.append(bytes(q, hl)); q += hl
                        let dl = num(q, 2); q += 2
                        def = bytes(q, min(dl, end - q)); q += dl
                        while q < end { let al = Int(p[q]); q += 1; heads.append(bytes(q, al)); q += al }
                    }
                    // control code 0x14 ends the definition proper (what follows is part-of-speech data)
                    if let cut = def.firstIndex(of: 0x14) { def = def.subdata(in: def.startIndex..<cut) }
                    for h in heads where !h.isEmpty {
                        var w = text(h)
                        if let dollar = w.firstIndex(of: "$") { w = String(w[..<dollar]) }     // "word$1$" numbering
                        w = w.trimmingCharacters(in: .whitespacesAndNewlines)
                        if w.isEmpty { continue }
                        if defs[w] == nil { order.append(w) }
                        defs[w, default: []].append(def)
                    }
                }
            }
        }
        guard !order.isEmpty else { return nil }
        var idx = Data(), dict = Data()
        for w in order {
            // several entries under one headword are shown one after another
            var body = Data()
            for (k, d) in (defs[w] ?? []).enumerated() {
                if k > 0 { body.append(Data("<br><br>".utf8)) }
                body.append(utf8 ? d : Data(text(d).utf8))
            }
            idx.append(Data(w.utf8)); idx.append(0)
            var o = UInt32(dict.count).bigEndian, s = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &o) { idx.append(contentsOf: $0) }
            withUnsafeBytes(of: &s) { idx.append(contentsOf: $0) }
            dict.append(body)
        }
        let ifo = "StarDict's dict ifo file\nversion=2.4.2\nwordcount=\(order.count)\nbookname=\(title)\nsametypesequence=h\n"
        guard (try? dict.write(to: dictURL, options: .atomic)) != nil,
              (try? Data(ifo.utf8).write(to: cache.appendingPathComponent("converted.ifo"))) != nil,
              (try? idx.write(to: idxURL, options: .atomic)) != nil else { return nil }
        return (idxURL, dictURL)
    }
}

/// One dictionary article, ready to show.
struct DictionaryArticle: Identifiable {
    var id: String { dictionary + "|" + word }
    var dictionary: String
    var word: String
    var body: AttributedString
}

/// Address of a cross-reference inside an article ("see 般泥洹").
func dictionaryLink(_ word: String) -> URL? {
    var c = URLComponents()
    c.scheme = "dcbt-dictionary"
    c.host = "lookup"
    c.queryItems = [URLQueryItem(name: "w", value: word)]
    return c.url
}

/// Turns a dictionary's markup into styled text. StarDict dictionaries use a
/// little Pango markup (<b>, <u>, <big>, <span foreground=…>) or HTML; Babylon
/// ones use HTML (<p>, <br>, <i>, <span style="color: …">, <a href="bword://…">).
func dictionaryText(_ raw: String, size: CGFloat) -> AttributedString {
    let out = NSMutableAttributedString()
    var bold = 0, under = 0, big = 0, italic = 0
    var colors: [NSColor?] = []         // one per open <span> / <font>
    var spanUnder: [Bool] = []
    var links: [URL?] = []
    let base = GaijiStore.shared.font("Songti TC", size: size)
    let boldFont = GaijiStore.shared.font("Songti TC Bold", size: size)
    let bigFont = GaijiStore.shared.font("Songti TC Bold", size: size + 3)
    func attrs() -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: big > 0 ? bigFont : (bold > 0 ? boldFont : base), .foregroundColor: NSColor.labelColor]
        if under > 0 || spanUnder.contains(true) { a[.underlineStyle] = NSUnderlineStyle.single.rawValue; a[.underlineColor] = NSColor.tertiaryLabelColor }
        if italic > 0 { a[.obliqueness] = 0.18 }
        if let c = colors.last(where: { $0 != nil }) ?? nil { a[.foregroundColor] = c }
        if let l = links.last ?? nil { a[.link] = l; a[.foregroundColor] = NSColor.linkColor }
        return a
    }
    var text = ""
    func flush() { if !text.isEmpty { out.append(NSAttributedString(string: text, attributes: attrs())); text = "" } }
    func newline() { if !(text.hasSuffix("\n") || (text.isEmpty && (out.length == 0 || out.string.hasSuffix("\n")))) { text += "\n" } }
    func color(in tag: String) -> NSColor? {
        // color: #8B0000 · color="#8B0000" · foreground="blue"
        guard let r = tag.range(of: "(?:color|foreground)\\s*[:=]\\s*[\"']?\\s*(#[0-9a-f]{6}|[a-z]+)", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let value = tag[r].lowercased().split(whereSeparator: { ":=\"' ".contains($0) }).last.map(String.init) ?? ""
        if value.hasPrefix("#"), let v = UInt32(value.dropFirst(), radix: 16) {
            let c = NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
            // dark colours meant for a white page would vanish on the off-black theme: use the system's red or blue instead
            let lum = 0.3 * c.redComponent + 0.59 * c.greenComponent + 0.11 * c.blueComponent
            if lum < 0.35 { return c.redComponent > c.blueComponent ? NSColor.systemRed : NSColor.systemBlue }
            return c
        }
        switch value {
        case "blue": return .systemBlue
        case "red": return .systemRed
        case "green": return .systemGreen
        case "gray", "grey": return .secondaryLabelColor
        default: return nil
        }
    }
    var i = raw.startIndex
    while i < raw.endIndex {
        let c = raw[i]
        if c == "<", let close = raw[i...].firstIndex(of: ">") {
            let tag = String(raw[raw.index(after: i)..<close])
            let name = tag.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" && false }).first.map(String.init) ?? ""
            flush()
            switch name {
            case "b", "strong": bold += 1
            case "/b", "/strong": bold = max(bold - 1, 0)
            case "u": under += 1
            case "/u": under = max(under - 1, 0)
            case "i", "em", "emph": italic += 1
            case "/i", "/em", "/emph": italic = max(italic - 1, 0)
            case "big": big += 1
            case "/big": big = max(big - 1, 0)
            case "span", "font":
                colors.append(color(in: tag))
                spanUnder.append(tag.lowercased().contains("border-bottom") || tag.lowercased().contains("underline"))
            case "/span", "/font":
                if !colors.isEmpty { colors.removeLast() }
                if !spanUnder.isEmpty { spanUnder.removeLast() }
            case "a":
                var url: URL? = nil
                if let r = tag.range(of: "bword://", options: .caseInsensitive) {
                    let word = tag[r.upperBound...].prefix { $0 != "\"" && $0 != "'" && $0 != ">" }
                    url = dictionaryLink(String(word).removingPercentEncoding ?? String(word))
                }
                links.append(url)
            case "/a": if !links.isEmpty { links.removeLast() }
            case "br", "br/", "p", "/p", "div", "/div", "li", "/ul", "/ol": newline(); if name == "li" { text += "· " }
            default: break
            }
            i = raw.index(after: close)
            continue
        }
        if c == "&", let semi = raw[i...].prefix(10).firstIndex(of: ";") {
            let entity = raw[i...semi]
            switch entity {
            case "&lt;": text += "<"
            case "&gt;": text += ">"
            case "&amp;": text += "&"
            case "&quot;": text += "\""
            case "&apos;": text += "'"
            case "&nbsp;": text += " "
            default:
                // &#27861; and &#x6CD5;
                let body = entity.dropFirst(2).dropLast()
                if entity.hasPrefix("&#x"), let v = UInt32(body.dropFirst(), radix: 16), let u = Unicode.Scalar(v) { text.unicodeScalars.append(u) }
                else if entity.hasPrefix("&#"), let v = UInt32(body), let u = Unicode.Scalar(v) { text.unicodeScalars.append(u) }
                else { text += String(entity) }
            }
            i = raw.index(after: semi)
            continue
        }
        text.append(c)
        i = raw.index(after: i)
    }
    flush()
    // no blank lines at the very end
    while out.length > 0, out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
    return AttributedString(out)
}

extension AppState {
    /// Moves a dictionary up or down the list: lookups show their results in that order.
    func moveDictionary(_ id: String, by step: Int) {
        var ids = dictionarySources.map { $0.id }
        guard let i = ids.firstIndex(of: id), ids.indices.contains(i + step) else { return }
        ids.swapAt(i, i + step)
        UserDefaults.standard.set(ids, forKey: "dictionary.order")
        loadDictionaries()
    }

    /// Finds the dictionaries in the folder and loads the ones that are switched on.
    func loadDictionaries() {
        // in the order the user gave them; ones not placed yet come last, as found
        let order = UserDefaults.standard.stringArray(forKey: "dictionary.order") ?? []
        let found = DictionaryInstaller.scan()
        let sources = order.compactMap { id in found.first { $0.id == id } } + found.filter { !order.contains($0.id) }
        dictionarySources = sources
        let off = Set(UserDefaults.standard.stringArray(forKey: "dictionary.off") ?? [])
        dictionaryOff = off
        dictionaryGeneration += 1
        let gen = dictionaryGeneration
        let wanted = sources.filter { !off.contains($0.id) }
        dictionariesLoading = !wanted.isEmpty
        let already = Dictionary(uniqueKeysWithValues: dictionaries.map { ($0.sourceId, $0) })
        DispatchQueue.global(qos: .utility).async {
            var loaded: [LoadedDictionary] = []
            var failed: [String] = []
            for s in wanted {
                if let d = already[s.id] { loaded.append(d); continue }
                if let files = DictionaryInstaller.prepare(s, status: { m in DispatchQueue.main.async { self.dictionaryStatus = m } }),
                   let d = LoadedDictionary(idx: files.idx, dict: files.dict, sourceId: s.id) {
                    loaded.append(d)
                } else { failed.append(s.id) }
            }
            DispatchQueue.main.async {
                guard gen == self.dictionaryGeneration else { return }
                self.dictionaries = loaded
                self.dictionaryFailed = Set(failed)
                self.dictionariesLoading = false
                self.dictionaryStatus = ""
                if !self.dictionaryQuery.isEmpty { self.lookUp(self.dictionaryQuery, log: false) }
            }
        }
    }

    func setDictionary(_ id: String, on: Bool) {
        var off = dictionaryOff
        if on { off.remove(id) } else { off.insert(id) }
        UserDefaults.standard.set(Array(off).sorted(), forKey: "dictionary.off")
        loadDictionaries()
    }

    func openDictionariesFolder() {
        let dir = AppPaths.dictionariesDir ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Dictionaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// Looks a word up in every dictionary that is switched on: the whole word,
    /// then, for a word of several characters, each character.
    /// `log: false` when the same word is only being shown again (other font, other order).
    func lookUp(_ text: String, log: Bool = true) {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let han = String(word.filter { AppState.hanCount(String($0)) > 0 })
        // a selection from the text is Chinese characters only; a cross-reference may be anything
        let key = han.isEmpty ? word : han
        dictionaryQuery = key
        var words = [key]
        if !han.isEmpty, han.count > 1 { words += han.map(String.init) }
        var out: [DictionaryArticle] = []
        for d in dictionaries {
            var seen = Set<String>()
            for w in words where seen.insert(w).inserted {
                if let raw = d.lookup(w) { out.append(DictionaryArticle(dictionary: d.name, word: w, body: dictionaryText(raw, size: paneFontSize))) }
            }
        }
        dictionaryArticles = out
        guard log else { return }
        var place = ""
        if let ix = index, let ti = readerText {
            place = ix.texts[ti].id + " " + ix.texts[ti].title + (currentPlace().map { ", p. " + prettyLbn($0.lbn) } ?? "")
        }
        let found = out.map { $0.dictionary }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        ActivityLog.dictionary.add(key, place, found.isEmpty ? "no entry" : found.joined(separator: "; "))
    }
}
