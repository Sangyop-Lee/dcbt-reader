import Foundation

/// Headless entry points used for building the index and for testing.
func runCLI(_ args: [String]) -> Int32 {
    func val(_ k: String) -> String? {
        guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    if let w = val("--dict") {
        // looks words up in every dictionary in the Dictionaries folder
        let sources = DictionaryInstaller.scan()
        if sources.isEmpty { print("no dictionaries found"); return 1 }
        for s in sources {
            guard let files = DictionaryInstaller.prepare(s, status: { print("  " + $0) }),
                  let d = LoadedDictionary(idx: files.idx, dict: files.dict, sourceId: s.id) else { print("CANNOT READ \(s.id)"); continue }
            print("\(s.id) [\(s.kindLabel)] \(d.name): \(d.count) entries")
            for one in w.split(separator: "|") {
                let raw = d.lookup(String(one))
                print("  == \(one): \(raw == nil ? "no entry" : String(String(dictionaryText(raw!, size: 15).characters).prefix(110)).replacingOccurrences(of: "\n", with: " / "))")
            }
        }
        return 0
    }
    let dest = URL(fileURLWithPath: val("--index") ?? AppPaths.indexDir.path)
    if let src = val("--build") {
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let t0 = Date()
        do {
            try buildIndex(source: URL(fileURLWithPath: src), dest: dest) { d, n in
                if d % 400 == 0 || d == n { FileHandle.standardError.write("  \(d)/\(n)\n".data(using: .utf8)!) }
            }
        } catch { print("error: \(error.localizedDescription)"); return 1 }
        print(String(format: "built in %.1fs", Date().timeIntervalSince(t0)))
    }
    guard let ix = CorpusIndex(dir: dest) else { print("no index at \(dest.path)"); return 1 }
    print("index: \(ix.texts.count) texts, \(ix.searchCount) search units, \(ix.lineCount) lines")
    let eng = SearchEngine(ix)
    var filter = ScopeFilter()
    if let s = val("--slr"), let f = parseSLR(URL(fileURLWithPath: s)) { filter.slr = Set(f.ids); print("slr \(f.name): \(f.ids.count) ids") }
    if let s = val("--title") { filter.title = s }
    if let s = val("--author") { filter.author = s }
    if let s = val("--era") { filter.era = s }
    let mask = scopeMask(ix.texts, filter)
    if let m = mask { print("scope: \(m.filter { $0 }.count) texts") }
    let show = Int(val("--show") ?? "5") ?? 5
    func dump(_ search: () -> SearchResult) {
        let t0 = Date()
        let r = search()
        let texts = Set(r.hits.map { ix.textIndex(at: Int($0.start)) }).count
        print(String(format: "%d hits in %d texts (%.3fs)%@", r.hits.count, texts, Date().timeIntervalSince(t0), r.truncated ? " TRUNCATED" : ""))
        for h in r.hits.prefix(show) {
            let s = ix.snippet(start: Int(h.start), end: Int(h.end), marks: [])
            let t = ix.texts[s.textIndex]
            print("  \(t.id) \(t.title) j\(t.juans[s.juan].n) p\(prettyLbn(s.lbn)): " + s.segs.map { $0.hit ? "[\($0.text)]" : $0.text }.joined())
        }
    }
    if let q = val("--search") { dump { eng.keyword(q, scope: mask, maxStar: 10) } }
    if let q = val("--near") {
        let terms = q.split(separator: " ").map(String.init)
        dump { eng.proximity(terms: terms, distance: Int(val("--dist") ?? "20") ?? 20, ordered: args.contains("--ordered"), scope: mask, maxStar: 10) }
    }
    if let q = val("--ref") {
        // shows how citations typed in the search box are understood
        for one in q.split(separator: "|") {
            guard let r = parseCanonRef(String(one)) else { print("NOT A CITATION  \(one)"); continue }
            guard let loc = ix.locate(r) else { print("NOT FOUND       \(one)"); continue }
            let end = loc.line >= 0 && loc.endLine > loc.line ? " … " + prettyLbn(unpackLbn(ix.lines[loc.endLine].lbn)) : ""
            print("\(loc.exact ? "ok  " : "near") \(one)  =>  \(ix.citation(text: loc.textIndex, line: loc.line))\(end)\(loc.juan.map { " juan \($0)" } ?? "")  \(ix.texts[loc.textIndex].title)")
        }
    }
    if let q = val("--cite") {
        // "T30n1581|5|若彼聞已": copies that passage of that juan as Copy with Citation would
        let p = q.components(separatedBy: "|")
        guard p.count == 3, let ti = ix.texts.firstIndex(where: { $0.id == p[0] }), let n = Int(p[1]),
              let doc = CBETAParser.parse(url: URL(fileURLWithPath: ix.meta.sourcePath).appendingPathComponent(ix.texts[ti].path)) else { print("usage: --cite id|juan|text"); return 1 }
        let t = ix.texts[ti]
        if args.contains("--headings") {
            // the chapter headings the parser kept, with their levels
            var lb = ""
            for tok in doc.toks {
                if case .lb(let n) = tok { lb = n }
                if case .section(let name, let level) = tok { print(lb, level, name.isEmpty ? "—" : name) }
            }
            return 0
        }
        let r = renderJuan(doc: doc, juan: t.juans.firstIndex { $0.n == n } ?? 0, options: RenderOptions(lineMode: args.contains("--lines")), marks: [], focus: nil)
        let range = (r.attr.string as NSString).range(of: p[2])
        guard range.location != NSNotFound, let s = citationSource(rendered: r, selection: range, text: t, juan: n) else { print("passage not found"); return 1 }
        for f in CiteFormat.presets { print(f.make().render(s)); print("") }
        // the user's own wording for canon, column and chapter
        var own = CiteFormat.standard
        for i in own.pieces.indices {
            let k = own.pieces[i].kind
            if k == .canon { own.pieces[i].style = k.styles.count; own.pieces[i].custom = ["Taishō shinshū daizōkyō ", "Zokuzōkyō "] }
            if k == .column { own.pieces[i].style = k.styles.count; own.pieces[i].custom = ["upper ", "middle ", "lower "] }
        }
        print(own.render(s))
    }
    if let q = val("--compare") {
        // "T30n1581|T30n1582": how much of the first text is in passages shared with the second
        let p = q.components(separatedBy: "|")
        guard p.count == 2, let a = ix.textIndexById[p[0]], let b = ix.textIndexById[p[1]] else { print("usage: --compare id|id"); return 1 }
        let t0 = Date()
        let levels = sharedNgramLevels(ix, text: a, with: b)
        var counts = [Int](repeating: 0, count: 9)
        for l in levels { counts[Int(l)] += 1 }
        print(String(format: "%@ (%d characters) against %@: %.2fs", ix.texts[a].title, levels.count, ix.texts[b].title, Date().timeIntervalSince(t0)))
        for n in 3...8 { print("  longest shared run \(n)\(n == 8 ? "+" : ""): \(counts[n]) characters") }
        if let k = levels.firstIndex(of: 8) {
            var e = k
            while e < levels.count, levels[e] == 8 { e += 1 }
            let from = ix.texts[a].searchStart + k
            print("  first long shared run: " + String(utf16CodeUnits: ix.search + from, count: min(e - k, 40)))
            if let run = ix.longestShared(around: from + 2, in: a, with: b, seed: 8) {
                print("  longest shared passage there (\(run.count) characters): " + String(utf16CodeUnits: ix.search + run.lowerBound, count: run.count))
            }
            if let j = ix.firstOccurrence(of: from, count: 8, in: b) { print("  found in the other text at p. " + prettyLbn(unpackLbn(ix.lines[ix.lineIndex(at: j, text: b)].lbn))) }
        }
    }
    let size = PassageSize(rawValue: val("--size") ?? "large") ?? .large
    if let q = val("--semantic") {
        guard let emb = SemanticIndex.bestEmbedder() else { print("no language model"); return 1 }
        let sem = SemanticIndex(ix: ix, dir: URL(fileURLWithPath: val("--semdir") ?? AppPaths.semanticDir.path), embedder: emb, size: size)
        let todo = ix.texts.indices.filter { mask?[$0] ?? true }
        let t0 = Date()
        let ok = sem.build(texts: todo) { d, n, s in FileHandle.standardError.write("  \(d)/\(n) \(s)\n".data(using: .utf8)!) }
        print(String(format: "semantic build ok=%@ %.1fs, %d texts indexed", ok ? "yes" : "no", Date().timeIntervalSince(t0), sem.indexedCount))
        for one in q.split(separator: "|") {
            let t1 = Date()
            let hits = sem.similar(String(one), scope: mask)
            print(String(format: "QUERY %@ (%.3fs)", String(one), Date().timeIntervalSince(t1)))
            for h in hits.prefix(show) {
                let t = ix.texts[h.textIndex]
                print(String(format: "  %.3f %@ %@ p%@: %@", h.score, t.id, t.title, prettyLbn(unpackLbn(ix.lines[h.line].lbn)), String(sem.text(of: h).prefix(70))))
            }
        }
    }
    return 0
}
