import SwiftUI
import AppKit

enum SearchMode { case keyword, proximity, semantic }

/// How the edition's line numbers are shown in the reader.
enum LineStyle: String, CaseIterable, Identifiable {
    case flow = "Running text"
    case inline = "Line numbers in the text"
    case lines = "Line by line"
    var id: String { rawValue }
}

enum Theme: String, CaseIterable, Identifiable {
    case paper = "Off-white"
    case ink = "Off-black"
    case sage = "Beige-green"
    var id: String { rawValue }
    var isDark: Bool { self == .ink }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }
    /// Main background (reader, results).
    var background: NSColor {
        switch self {
        case .paper: return Theme.rgb(250, 249, 245)
        case .ink: return Theme.rgb(38, 38, 36)
        case .sage: return Theme.rgb(229, 232, 214)
        }
    }
    /// Slightly deeper tone for the side column and bars.
    var panel: NSColor {
        switch self {
        case .paper: return Theme.rgb(240, 238, 230)
        case .ink: return Theme.rgb(31, 30, 29)
        case .sage: return Theme.rgb(216, 220, 198)
        }
    }
}

enum Column: String { case sidebar, results, reader, variants }

struct TextGroup: Identifiable {
    var ti: Int
    var count: Int
    var firstRow: Int       // for keyword/proximity hits (contiguous rows)
    var id: Int { ti }
}

struct ResultSet {
    enum Kind { case catalog, hits, semantic }
    var kind = Kind.catalog
    var hits: [Hit] = []
    var subSpans: [UInt32] = []
    var termCount = 0
    var sem: [SemHit] = []
    var groups: [TextGroup] = []
    var truncated = false
    var seconds = 0.0
    var query = ""
    var total: Int { kind == .semantic ? sem.count : hits.count }
}

/// Tells the variants list which row to bring to its centre.
final class VariantScroller: ObservableObject {
    @Published var version = 0      // changes on every request, so asking for the same row twice still scrolls
    var target: Int? = nil
    var settle = true               // repeat the scroll once more a moment later (a far-away row may not be laid out yet)
    func show(_ id: Int, settle: Bool) {
        target = id
        self.settle = settle
        version += 1
    }
}

final class AppState: ObservableObject {
    // library
    @Published var sourceURL: URL?
    @Published var slrURL: URL?
    @Published var index: CorpusIndex?
    @Published var indexProgress: Double? = nil
    @Published var libraryMessage = ""
    var engine: SearchEngine?

    // the search box: several terms separated by spaces are a proximity search; "by meaning" is semantic
    @Published var query = ""
    @Published var byMeaning = false
    /// The search box either searches or goes to a citation; the menu before it chooses which.
    @Published var goToMode = false
    @Published var distance = 20
    @Published var ordered = false
    @Published var maxStar = 10
    @Published var showHelp = false
    var queryTerms: [String] {
        query.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" || $0.isNewline || $0 == "\t" }).map(String.init)
    }
    var mode: SearchMode { byMeaning ? .semantic : (queryTerms.count > 1 ? .proximity : .keyword) }

    // scope
    @Published var slrFiles: [SLRFile] = []
    @Published var selectedSLR = ""          // SLRFile.id, "" = none
    @Published var titleFilter = ""
    @Published var authorFilter = ""
    @Published var eraFilter = ""
    @Published var onlyCurrentText = false   // limit searches to the text open in the reader
    @Published var eras: [(name: String, count: Int)] = []
    @Published var scopeCount = 0
    @Published var slrMissing: [String] = []
    private var mask: [Bool]? = nil

    // results
    @Published var result = ResultSet()
    @Published var searching = false
    @Published var status = ""
    @Published var selectedText: Int? = nil
    @Published var rows: [Int] = []
    @Published var rowTotal = 0
    @Published var selectedRow: Int? = nil
    @Published var sortByCount = false
    private var pageLimit = 500
    private var generation = 0

    // search by meaning: one index per passage size
    var semantics: [PassageSize: SemanticIndex] = [:]
    @Published var passageSize = PassageSize.large
    @Published var allSizes = false          // search every passage size and merge the results
    @Published var semBuilding = false
    @Published var semProgress = 0.0
    @Published var semStatus = ""
    @Published var semIndexedInScope = 0
    @Published var semCoverage: [PassageSize: Int] = [:]
    private var semCancelled = false
    private var coverageTimer: Timer?
    var semantic: SemanticIndex? { semantics[passageSize] }
    /// The indexes a by-meaning search uses now.
    var activeSemantics: [SemanticIndex] {
        allSizes ? PassageSize.allCases.compactMap { semantics[$0] } : [semantic].compactMap { $0 }
    }

    // reader
    @Published var readerText: Int? = nil
    @Published var readerJuan = 0
    @Published var edition = ""              // "" = CBETA base text
    @Published var lineStyle = LineStyle.flow
    @Published var fontSize: Double = 18
    @Published var rendered: RenderedJuan? = nil
    @Published var renderVersion = 0
    @Published var scrollTo: NSRange? = nil
    @Published var scrollVersion = 0
    @Published var scrollAlignTop = false
    @Published var selectedApp: Int? = nil
    @Published var location = ""
    @Published var readerLoading = false
    /// Cached for the toolbar, so that drawing it never searches the results.
    @Published var matchInfo: (pos: Int, total: Int) = (0, 0)
    @Published var bookmarkedHere = false
    @Published var bookmarks: [Bookmark] = []
    var topProbe: (() -> Int)? = nil
    var caretLbn: String? = nil              // line the caret is on, nil until it is placed in this juan
    var pendingLbn: String? = nil            // line to bring to the top after the next render
    private var focus: Range<Int>? = nil     // file-relative search units
    private var focusParts: [Range<Int>] = []
    private var focusQuiet = false           // the focus is a cited place, not a search hit
    private var focusDisp: Range<Int>? = nil // an exact passage (file-relative display offsets) to highlight instead
    private var docCache: [(String, ParsedDoc)] = []
    private let readerQueue = DispatchQueue(label: "reader")
    private var readerGeneration = 0
    private var restoredPlace = false

    // variants pane following the text. Kept apart from the rest of the state: it changes many
    // times a second while the text scrolls, and only the variants list needs to hear about it.
    let variantScroller = VariantScroller()
    private var nearApp: Int? = nil          // variant nearest to the place being read
    private var lastFollow = Date.distantPast
    private var variantFollowPausedUntil = Date.distantPast

    // dictionaries
    @Published var bottomTab = BottomTab.variants
    @Published var dictionarySources: [DictionarySource] = []
    @Published var dictionaries: [LoadedDictionary] = []
    @Published var dictionaryOff: Set<String> = []          // dictionaries the user has switched off
    @Published var dictionaryFailed: Set<String> = []       // found but could not be read
    @Published var dictionariesLoading = false
    @Published var dictionaryStatus = ""                    // progress while a dictionary is being prepared
    @Published var showDictionarySettings = false
    // text sizes of the pane under the text, the list of texts and the list of results
    @Published var paneFontSize = CGFloat(UserDefaults.standard.object(forKey: "paneFontSize") as? Double ?? 15)
    @Published var sidebarFontSize = CGFloat(UserDefaults.standard.object(forKey: "sidebarFontSize") as? Double ?? 13)
    @Published var resultsFontSize = CGFloat(UserDefaults.standard.object(forKey: "resultsFontSize") as? Double ?? 14)
    @Published var showCitationSettings = false
    // comparing the text being read with another: the passages they share
    @Published var compareOther: Int? = nil
    @Published var comparing = false
    @Published var showComparePicker = false
    @Published var compareQuery = ""
    @Published var ngramMin = max(UserDefaults.standard.integer(forKey: "ngramMin"), 3)
    var compareLevels: [UInt8]? = nil       // per searchable character of the text being read: longest shared run, 0 or 3…8
    var compareCache: [(a: Int, b: Int, levels: [UInt8])] = []
    var compareGeneration = 0
    // places left behind by a jump, for the back and forward buttons
    typealias Place = (ti: Int, juan: Int, lbn: String)
    @Published var backStack: [Place] = []
    @Published var forwardStack: [Place] = []
    private var travelling = false
    var sharedHover: (version: Int, attr: NSRange, text: String)? = nil    // the shared passage last pointed at
    let citation = CitationSettings()
    var selectionRange = NSRange()      // the selection in the reader; not published, it changes with every drag
    @Published var dictionaryQuery = ""
    @Published var dictionaryArticles: [DictionaryArticle] = []
    var dictionaryGeneration = 0

    // translation
    @Published var translationSource = ""
    @Published var translationResult = ""
    @Published var translationError = ""
    @Published var translating = false
    @Published var translationProvider = TranslationProvider.openai
    @Published var translationModel = ""
    @Published var translationLanguage = TranslationLanguage.korean
    @Published var showTranslationSettings = false
    @Published var recentSearches: [String] = ActivityLog.recentSearches().map { $0.query }
    /// Which of the recent entries were citations, so that picking one goes to it again.
    var recentCitations: Set<String> = Set(ActivityLog.recentSearches().filter { $0.citation }.map { $0.query })
    @Published var showRecentSearches = false
    var selectionGeneration = 0
    var translationGeneration = 0

    // appearance and layout
    let layout = PaneLayout()
    @Published var theme = Theme.paper
    @Published var showSidebar = true
    @Published var showResults = true
    @Published var showReader = true
    @Published var showVariants = true

    func setTheme(_ t: Theme) {
        theme = t
        UserDefaults.standard.set(t.rawValue, forKey: "theme")
        applyTheme()
    }

    func applyTheme() {
        NSApp.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        for w in NSApp.windows where w.contentView != nil && !(w is NSPanel) {
            w.backgroundColor = theme.panel
            w.titlebarAppearsTransparent = true
        }
    }

    func isShown(_ c: Column) -> Bool {
        switch c {
        case .sidebar: return showSidebar
        case .results: return showResults
        case .reader: return showReader
        case .variants: return showVariants
        }
    }

    /// Shows or hides a column; the last visible column cannot be hidden.
    func toggle(_ c: Column) {
        let visible = [showSidebar, showResults, showReader].filter { $0 }.count
        if c != .variants && isShown(c) && visible <= 1 { return }
        switch c {
        case .sidebar: showSidebar.toggle()
        case .results: showResults.toggle()
        case .reader: showReader.toggle()
        case .variants: showVariants.toggle()
        }
        UserDefaults.standard.set(isShown(c), forKey: "show." + c.rawValue)
    }

    // MARK: start-up

    init() {
        let d = UserDefaults.standard
        let beside = Bundle.main.bundleURL.deletingLastPathComponent()
        func pick(_ key: String, _ name: String) -> URL? {
            let fm = FileManager.default
            let near = beside.appendingPathComponent(name)
            if fm.fileExists(atPath: near.path) { return near }
            if let p = d.string(forKey: key), fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
            return nil
        }
        sourceURL = pick("sourcePath", "Source texts")
        slrURL = pick("slrPath", "SLR files")
        if let v = d.object(forKey: "fontSize") as? Double { fontSize = v }
        if let v = d.string(forKey: "theme"), let t = Theme(rawValue: v) { theme = t }
        if let v = d.string(forKey: "lineStyle"), let l = LineStyle(rawValue: v) { lineStyle = l }
        loadTranslationSettings()
        loadDictionaries()
        installArrowKeys()
        allSizes = d.bool(forKey: "allSizes")
        if let v = d.string(forKey: "passageSize"), let p = PassageSize(rawValue: v) { passageSize = p }
        if let v = d.object(forKey: "show.sidebar") as? Bool { showSidebar = v }
        if let v = d.object(forKey: "show.results") as? Bool { showResults = v }
        if let v = d.object(forKey: "show.reader") as? Bool { showReader = v }
        if let v = d.object(forKey: "show.variants") as? Bool { showVariants = v }
        if !showSidebar && !showResults && !showReader { showReader = true }
        reloadSLR()
        DispatchQueue.main.async { self.loadIndex(buildIfMissing: true); self.applyTheme() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.applyTheme() }
    }

    func reloadSLR() {
        slrFiles = slrURL.map(loadSLRFiles) ?? []
        if !slrFiles.contains(where: { $0.id == selectedSLR }) { selectedSLR = "" }
    }

    func chooseFolder(source: Bool) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = source ? "Choose the folder that holds the CBETA XML files (T, X …)" : "Choose the folder that holds the .slr files"
        guard p.runModal() == .OK, let u = p.url else { return }
        if source {
            sourceURL = u
            UserDefaults.standard.set(u.path, forKey: "sourcePath")
            rebuildIndex()
        } else {
            slrURL = u
            UserDefaults.standard.set(u.path, forKey: "slrPath")
            reloadSLR()
            filtersChanged()
        }
    }

    func loadIndex(buildIfMissing: Bool) {
        if let ix = CorpusIndex(dir: AppPaths.indexDir),
           sourceURL == nil || ix.meta.sourcePath == sourceURL!.path {
            adopt(ix)
        } else if buildIfMissing, sourceURL != nil {
            rebuildIndex()
        } else if sourceURL == nil {
            libraryMessage = "Choose the folder that holds the CBETA XML files."
        }
    }

    private func adopt(_ ix: CorpusIndex) {
        index = ix
        engine = SearchEngine(ix)
        semantics = [:]
        if let emb = SemanticIndex.bestEmbedder() {
            for size in PassageSize.allCases { semantics[size] = SemanticIndex(ix: ix, dir: AppPaths.semanticDir, embedder: emb, size: size, load: false) }
        }
        var c: [String: Int] = [:]
        for t in ix.texts { c[t.era, default: 0] += 1 }
        eras = c.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }.sorted {
            let a = eraStartYear[$0.0] ?? 2500, b = eraStartYear[$1.0] ?? 2500
            return a != b ? a < b : $0.0 < $1.0
        }
        libraryMessage = ""
        filtersChanged()
        if !restoredPlace {
            restoredPlace = true
            loadBookmarks()
            restoreLastPlace()
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.saveLastPlace()
            }
        }
    }

    func rebuildIndex() {
        guard let src = sourceURL, indexProgress == nil else { return }
        indexProgress = 0
        libraryMessage = "Reading the XML files and building the search index…"
        index = nil; engine = nil; semantics = [:]
        compareOther = nil; compareLevels = nil; compareCache = []
        backStack = []; forwardStack = []
        result = ResultSet(); rows = []; rendered = nil; readerText = nil
        let dest = AppPaths.indexDir
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            var err: String? = nil
            do {
                try buildIndex(source: src, dest: dest) { d, n in
                    DispatchQueue.main.async { self.indexProgress = Double(d) / Double(max(n, 1)) }
                }
            } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                self.indexProgress = nil
                if let e = err { self.libraryMessage = "Could not build the index: \(e)"; return }
                if let ix = CorpusIndex(dir: dest) { self.adopt(ix) }
                else { self.libraryMessage = "The index could not be opened after building." }
            }
        }
    }

    // MARK: scope

    var filter: ScopeFilter {
        var f = ScopeFilter()
        if let s = slrFiles.first(where: { $0.id == selectedSLR }) { f.slr = Set(s.ids) }
        f.title = titleFilter; f.author = authorFilter; f.era = eraFilter
        if onlyCurrentText { f.only = readerText }
        return f
    }

    func clearFilters() {
        selectedSLR = ""; titleFilter = ""; authorFilter = ""; eraFilter = ""; onlyCurrentText = false
        filtersChanged()
    }

    func filtersChanged(rerun: Bool = true) {
        guard let ix = index else { return }
        let f = filter
        mask = scopeMask(ix.texts, f)
        scopeCount = mask?.filter { $0 }.count ?? ix.texts.count
        if let s = f.slr {
            let have = Set(ix.texts.map { $0.id })
            slrMissing = s.filter { id in !have.contains(id) && !ix.texts.contains(where: { slrMatches([id], id: $0.id) }) }.sorted()
        } else { slrMissing = [] }
        updateSemCoverage()
        if !rerun { return }
        if mode == .semantic && !query.trimmingCharacters(in: .whitespaces).isEmpty {
            status = "Scope changed — press Return to search again."
            return
        }
        runSearch()
    }

    /// Chooses the passage size for by-meaning search, or all sizes together.
    func setPassages(_ size: PassageSize? = nil) {
        allSizes = size == nil
        if let s = size { passageSize = s; UserDefaults.standard.set(s.rawValue, forKey: "passageSize") }
        UserDefaults.standard.set(allSizes, forKey: "allSizes")
        updateSemCoverage()
        if byMeaning && !query.trimmingCharacters(in: .whitespaces).isEmpty { runSearch() }
    }

    /// Reads the stored by-meaning indexes (and whatever a running build has added) off the main thread.
    func loadSemantics(then done: @escaping () -> Void = {}) {
        let sems = Array(semantics.values)
        DispatchQueue.global(qos: .userInitiated).async {
            sems.forEach { $0.refresh() }
            DispatchQueue.main.async { self.updateSemCoverage(); done() }
        }
    }

    func updateSemCoverage() {
        let sems = activeSemantics
        guard let ix = index, !sems.isEmpty else { semIndexedInScope = 0; return }
        // with all sizes: texts that at least one size has indexed
        var n = 0
        for i in ix.texts.indices where (mask?[i] ?? true) && sems.contains(where: { $0.isIndexed(i) }) { n += 1 }
        semIndexedInScope = n
        var per: [PassageSize: Int] = [:]
        for (size, sem) in semantics {
            var c = 0
            for i in ix.texts.indices where (mask?[i] ?? true) && sem.isIndexed(i) { c += 1 }
            per[size] = c
        }
        semCoverage = per
        // an index may be growing in the background: look again every half minute while by-meaning is on
        if coverageTimer == nil {
            coverageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                guard let self = self, self.byMeaning, !self.semBuilding else { return }
                self.loadSemantics()
            }
        }
    }

    // MARK: search

    func runSearch() {
        guard let ix = index, let eng = engine else { return }
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let mask = self.mask
        selectedText = nil
        selectedRow = nil
        pageLimit = 500
        if q.isEmpty {
            var rs = ResultSet()
            rs.groups = ix.texts.indices.filter { mask?[$0] ?? true }.map { TextGroup(ti: $0, count: 0, firstRow: 0) }
            result = rs
            searching = false
            status = "\(rs.groups.count) texts"
            refreshRows()
            return
        }
        showRecentSearches = false
        if recentSearches.first != q {
            let kind = goToMode ? "citation" : byMeaning ? "by meaning" : queryTerms.count > 1 ? "proximity" : "keyword"
            ActivityLog.searches.add(kind, q)
            if goToMode { recentCitations.insert(q) } else { recentCitations.remove(q) }
            recentSearches = Array(([q] + recentSearches.filter { $0 != q }).prefix(20))
        }
        // "Go to": a citation such as "T 2145: 55.63b20" opens that place; nothing is searched
        if goToMode {
            searching = false
            if let ref = parseCanonRef(q), let loc = ix.locate(ref) {
                goTo(loc)
            } else {
                status = parseCanonRef(q) == nil
                    ? "Not a citation I can read. Try T 2145: 55.63b20, T55n2145_p0063b20 or T2145 — or switch the menu to Search."
                    : "No such text or page is in the library."
            }
            return
        }
        if mode == .semantic {
            if activeSemantics.contains(where: { !$0.loaded }) {
                // first by-meaning search since launch: read the stored index, then come back
                searching = true
                status = "Opening the meaning index…"
                loadSemantics { if gen == self.generation { self.runSearch() } }
                return
            }
            updateSemCoverage()
            if semIndexedInScope == 0 {
                result = ResultSet()
                searching = false
                status = "None of the texts in scope are in the meaning index yet. Press “Build for Texts in Scope” under the search field, then search again."
                refreshRows()
                return
            }
        }
        searching = true
        status = "Searching…"
        let mode = self.mode, terms = queryTerms, distance = self.distance, ordered = self.ordered, maxStar = self.maxStar
        let sems = activeSemantics
        DispatchQueue.global(qos: .userInitiated).async {
            var rs = ResultSet()
            rs.query = q
            let t0 = Date()
            switch mode {
            case .keyword:
                let r = eng.keyword(q, scope: mask, maxStar: maxStar)
                rs.kind = .hits; rs.hits = r.hits; rs.truncated = r.truncated
            case .proximity:
                let r = eng.proximity(terms: terms, distance: distance, ordered: ordered, scope: mask, maxStar: maxStar)
                rs.kind = .hits; rs.hits = r.hits; rs.subSpans = r.subSpans; rs.termCount = r.termCount; rs.truncated = r.truncated
            case .semantic:
                rs.kind = .semantic
                var all: [SemHit] = []
                for sem in sems {
                    all += sem.similar(q, scope: mask) { s in
                        DispatchQueue.main.async { if gen == self.generation { self.status = s } }
                    }
                }
                if sems.count > 1 {
                    // several sizes: best first, dropping a passage that overlaps a better one
                    all.sort { $0.score > $1.score }
                    var kept: [SemHit] = []
                    for h in all {
                        if kept.contains(where: { $0.textIndex == h.textIndex && $0.dispStart < h.dispEnd && h.dispStart < $0.dispEnd }) { continue }
                        kept.append(h)
                        if kept.count >= 200 { break }
                    }
                    all = kept
                }
                rs.sem = all
            }
            rs.seconds = Date().timeIntervalSince(t0)
            // group by text
            if rs.kind == .hits {
                var ti = -1
                var end = 0
                for (i, h) in rs.hits.enumerated() {
                    if ti < 0 || Int(h.start) >= end {
                        ti = ix.textIndex(at: Int(h.start))
                        end = ix.texts[ti].searchEnd + 1
                        rs.groups.append(TextGroup(ti: ti, count: 0, firstRow: i))
                    }
                    rs.groups[rs.groups.count - 1].count += 1
                }
            } else {
                var c: [Int: Int] = [:]
                for h in rs.sem { c[h.textIndex, default: 0] += 1 }
                rs.groups = c.map { TextGroup(ti: $0.key, count: $0.value, firstRow: 0) }.sorted { $0.ti < $1.ti }
            }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.result = rs
                self.searching = false
                let n = rs.total
                let nf = NumberFormatter(); nf.numberStyle = .decimal
                let count = nf.string(from: NSNumber(value: n)) ?? "\(n)"
                if rs.kind == .semantic {
                    let partial = self.semIndexedInScope < self.scopeCount
                        ? " — searched the \(self.semIndexedInScope) of \(self.scopeCount) texts in the meaning index" : ""
                    self.status = n == 0 ? "No similar passages found." : "\(count) most similar passages in \(rs.groups.count) texts (\(String(format: "%.1f", rs.seconds)) s)" + partial
                } else {
                    self.status = "\(count)\(rs.truncated ? "+" : "") hits in \(rs.groups.count) texts (\(String(format: "%.2f", rs.seconds)) s)"
                }
                self.refreshRows()
            }
        }
    }

    /// First row of `result.hits` starting at or after a search offset (hits are in text order).
    private func firstHit(from offset: Int) -> Int {
        let hits = result.hits
        var lo = 0, hi = hits.count
        while lo < hi { let m = (lo + hi) / 2; if Int(hits[m].start) < offset { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// The matched terms of a proximity hit, or the hit itself, as search ranges.
    private func termSpans(_ h: Hit) -> [Range<Int>] {
        guard h.sub >= 0, result.termCount > 0 else { return [Int(h.start)..<Int(h.end)] }
        let b = Int(h.sub) * 2 * result.termCount
        return (0..<result.termCount).map { Int(result.subSpans[b + 2 * $0])..<Int(result.subSpans[b + 2 * $0 + 1]) }
    }

    func refreshRows() {
        updateMatchInfo()
        var all: [Int] = []
        var total = 0
        switch result.kind {
        case .catalog:
            break
        case .hits:
            if let ti = selectedText, let g = result.groups.first(where: { $0.ti == ti }) {
                total = g.count
                all = Array(g.firstRow..<(g.firstRow + min(g.count, pageLimit)))
            } else {
                total = result.hits.count
                all = Array(0..<min(total, pageLimit))
            }
        case .semantic:
            let idx = result.sem.indices.filter { selectedText == nil || result.sem[$0].textIndex == selectedText }
            total = idx.count
            all = Array(idx.prefix(pageLimit))
        }
        rows = all
        rowTotal = total
    }

    func showMore() { pageLimit += 1000; refreshRows() }

    func selectText(_ ti: Int?) {
        selectedText = ti
        pageLimit = 500
        refreshRows()
        if result.kind == .catalog, let ti = ti { openReader(text: ti, juan: 0, focus: nil) }
    }

    var sortedGroups: [TextGroup] {
        if sortByCount && result.kind != .catalog { return result.groups.sorted { $0.count != $1.count ? $0.count > $1.count : $0.ti < $1.ti } }
        return result.groups
    }

    func snippet(row: Int) -> CorpusIndex.Snippet? {
        guard let ix = index else { return nil }
        switch result.kind {
        case .hits:
            guard row < result.hits.count else { return nil }
            let h = result.hits[row]
            return ix.snippet(start: Int(h.start), end: Int(h.end), marks: termSpans(h).map { ($0.lowerBound, $0.upperBound) })
        case .semantic:
            guard row < result.sem.count, let sem = semantic else { return nil }
            let h = result.sem[row]
            let text = sem.text(of: h, limit: 200)
            let s = Int(ix.lines[h.line].searchStart)
            return CorpusIndex.Snippet(segs: [(text, false)], textIndex: h.textIndex, lbn: unpackLbn(ix.lines[h.line].lbn),
                                       juan: ix.juanIndex(at: s, text: h.textIndex))
        case .catalog:
            return nil
        }
    }

    func openRow(_ row: Int) {
        guard let ix = index else { return }
        switch result.kind {
        case .hits:
            guard row < result.hits.count else { return }
            let h = result.hits[row]
            let ti = ix.textIndex(at: Int(h.start))
            let t = ix.texts[ti]
            // the separate terms are only marked for a proximity hit
            let parts = h.sub < 0 ? [] : termSpans(h).map { ($0.lowerBound - t.searchStart)..<($0.upperBound - t.searchStart) }
            openReader(text: ti, juan: ix.juanIndex(at: Int(h.start), text: ti),
                       focus: (Int(h.start) - t.searchStart)..<(Int(h.end) - t.searchStart), parts: parts)
        case .semantic:
            guard row < result.sem.count else { return }
            let h = result.sem[row]
            let t = ix.texts[h.textIndex]
            let s = Int(ix.lines[h.line].searchStart)
            let last = h.line + h.lineCount
            let e = last < t.firstLine + t.lineCount ? Int(ix.lines[last].searchStart) : t.searchEnd
            openReader(text: h.textIndex, juan: ix.juanIndex(at: s, text: h.textIndex),
                       focus: (s - t.searchStart)..<(max(e, s + 1) - t.searchStart),
                       dispFocus: (h.dispStart - t.dispStart)..<(h.dispEnd - t.dispStart))
        case .catalog:
            break
        }
    }

    // MARK: stepping through the matches of the text being read

    /// Result rows that fall in the text shown in the reader, in reading order.
    private func readerMatchRows() -> [Int] {
        guard let ix = index, let ti = readerText else { return [] }
        let t = ix.texts[ti]
        switch result.kind {
        case .hits:
            return Array(firstHit(from: t.searchStart)..<firstHit(from: t.searchEnd))
        case .semantic:
            return result.sem.indices.filter { result.sem[$0].textIndex == ti }.sorted { result.sem[$0].line < result.sem[$1].line }
        case .catalog:
            return []
        }
    }

    /// File-relative search offset where a result row starts.
    private func matchStart(_ row: Int) -> Int {
        guard let ix = index, let ti = readerText else { return 0 }
        let t = ix.texts[ti]
        if result.kind == .semantic { return Int(ix.lines[result.sem[row].line].searchStart) - t.searchStart }
        return Int(result.hits[row].start) - t.searchStart
    }

    /// (position of the match in focus, number of matches in this text); position 0 = none in focus.
    func updateMatchInfo() {
        var info = (pos: 0, total: 0)
        if let ix = index, let ti = readerText {
            let t = ix.texts[ti]
            switch result.kind {
            case .hits:
                // two binary searches give this text's share of the hits, a third the one in focus
                let lo = firstHit(from: t.searchStart), hi = firstHit(from: t.searchEnd)
                info.total = hi - lo
                if let f = focus {
                    let k = firstHit(from: f.lowerBound + t.searchStart)
                    if k < hi, Int(result.hits[k].start) == f.lowerBound + t.searchStart { info.pos = k - lo + 1 }
                }
            case .semantic:
                let rows = readerMatchRows()
                info.total = rows.count
                if let f = focus, let k = rows.firstIndex(where: { matchStart($0) == f.lowerBound }) { info.pos = k + 1 }
            case .catalog:
                break
            }
        }
        if info.pos != matchInfo.pos || info.total != matchInfo.total { matchInfo = info }
    }

    /// Jumps the reader to the next (d = 1) or previous (d = -1) match in this text, across juan.
    func stepMatch(_ d: Int) {
        guard let ix = index, let ti = readerText else { return }
        let rows = readerMatchRows()
        guard !rows.isEmpty else { return }
        let t = ix.texts[ti]
        var k: Int
        if let f = focus, let cur = rows.firstIndex(where: { matchStart($0) == f.lowerBound }) {
            k = cur + d
        } else {
            // nothing in focus: start from the juan on screen
            let here = readerJuan < t.juans.count ? t.juans[readerJuan].searchStart : 0
            let after = rows.firstIndex(where: { matchStart($0) >= here }) ?? rows.count
            k = d > 0 ? after : after - 1
        }
        if k < 0 { k = rows.count - 1 }
        if k >= rows.count { k = 0 }
        selectedRow = rows[k]
        openRow(rows[k])
    }

    // MARK: citation jump

    func goTo(_ loc: CanonLocation) {
        guard let ix = index else { return }
        let ti = loc.textIndex
        let t = ix.texts[ti]
        var rs = ResultSet()
        rs.groups = [TextGroup(ti: ti, count: 0, firstRow: 0)]
        result = rs
        selectedText = ti
        refreshRows()
        if loc.line < 0, let j = loc.juan {
            // a fascicle by its number; if the text has no such fascicle, the nearest one
            let k = t.juans.firstIndex(where: { $0.n == j }) ?? min(max(j - 1, 0), t.juans.count - 1)
            openReader(text: ti, juan: k, focus: nil)
            let have = t.juans.contains { $0.n == j }
            status = have ? "\(ix.citation(text: ti, line: -1)), juan \(j) — \(t.title)"
                          : "\(t.title) (\(t.id)) has no juan \(j); opened juan \(t.juans[k].n)."
        } else if loc.line < 0 {
            openReader(text: ti, juan: 0, focus: nil)
            status = loc.exact ? "\(ix.citation(text: ti, line: -1)) — \(t.title)"
                               : "\(t.title) (\(t.id)) does not have that page; opened at its beginning."
        } else {
            let s = Int(ix.lines[loc.line].searchStart)
            let after = loc.endLine + 1
            let e = after < t.firstLine + t.lineCount ? Int(ix.lines[after].searchStart) : t.searchEnd
            openReader(text: ti, juan: ix.juanIndex(at: s, text: ti),
                       focus: (s - t.searchStart)..<(max(e, s + 1) - t.searchStart), quiet: true)
            status = (loc.exact ? "" : "Nearest place: ") + "\(ix.citation(text: ti, line: loc.line)) — \(t.title)"
        }
    }

    // MARK: semantic vector index

    var semanticModelName: String { semantic?.embedder.label ?? "the Mac's language model" }

    func buildSemantic() {
        let sems = activeSemantics
        guard let ix = index, !sems.isEmpty, !semBuilding else { return }
        let todo = ix.texts.indices.filter { mask?[$0] ?? true }
        semBuilding = true
        semCancelled = false
        semProgress = 0
        semStatus = "Preparing…"
        DispatchQueue.global(qos: .utility).async {
            var ok = true
            for (k, sem) in sems.enumerated() where ok && !self.semCancelled {
                let label = sems.count > 1 ? "\(sem.size.label): " : ""
                sem.refresh()       // what is already stored must not be built again
                ok = sem.build(texts: todo) { d, n, s in
                    DispatchQueue.main.async {
                        self.semProgress = (Double(k) + Double(d) / Double(max(n, 1))) / Double(sems.count)
                        self.semStatus = label + s
                        if d % 5 == 0 { self.updateSemCoverage() }
                    }
                }
            }
            DispatchQueue.main.async {
                self.semBuilding = false
                self.semStatus = ok ? "" : "The on-device language model is not available on this Mac."
                self.updateSemCoverage()
            }
        }
    }

    func cancelSemantic() { semCancelled = true; semantics.values.forEach { $0.cancel() } }

    // MARK: reader

    func openReader(text ti: Int, juan: Int, focus: Range<Int>?, parts: [Range<Int>] = [], dispFocus: Range<Int>? = nil,
                    quiet: Bool = false) {
        guard let ix = index else { return }
        rememberPlace()
        let changedText = readerText != ti
        let previous = readerText
        if changedText, !edition.isEmpty, !ix.texts[ti].witnesses.contains(edition) { edition = "" }
        if !showReader { toggle(.reader) }
        readerText = ti
        if changedText, let other = compareOther {
            // opening the text compared with turns the comparison round
            if other == ti { compareOther = previous }
            prepareComparison(redraw: false)
        }
        // "only the text being read" follows the reader to the new text
        if changedText && onlyCurrentText { filtersChanged(rerun: false) }
        readerJuan = min(max(juan, 0), ix.texts[ti].juans.count - 1)
        self.focus = focus
        self.focusParts = parts
        self.focusDisp = dispFocus
        self.focusQuiet = quiet
        selectedApp = nil
        render(scroll: true)
    }

    /// Called before the reader jumps somewhere: the place being left can be come back to.
    private func rememberPlace() {
        guard !travelling, let p = currentPlace(), !p.lbn.isEmpty else { return }
        if let last = backStack.last, last.ti == p.ti, last.juan == p.juan, last.lbn == p.lbn { return }
        backStack.append(p)
        if backStack.count > 200 { backStack.removeFirst() }
        forwardStack = []
    }

    private func travel(from: inout [Place], to: inout [Place]) {
        guard let p = from.popLast() else { return }
        if let here = currentPlace() { to.append(here) }
        travelling = true
        openPlace(text: p.ti, juan: p.juan, lbn: p.lbn, highlight: false)
        travelling = false
    }

    func goBack() { travel(from: &backStack, to: &forwardStack) }
    func goForward() { travel(from: &forwardStack, to: &backStack) }

    func setJuan(_ j: Int) {
        guard let ix = index, let ti = readerText else { return }
        let n = ix.texts[ti].juans.count
        guard j >= 0, j < n, j != readerJuan else { return }
        rememberPlace()
        readerJuan = j
        (focus, focusParts, focusDisp, selectedApp) = (nil, [], nil, nil)
        render(scroll: false)
    }

    func setLineStyle(_ l: LineStyle) {
        lineStyle = l
        UserDefaults.standard.set(l.rawValue, forKey: "lineStyle")
        render(keepPlace: true)
    }

    func paneFont(_ name: String, _ delta: CGFloat = 0) -> Font {
        Font(GaijiStore.shared.font(name, size: paneFontSize + delta) as CTFont)
    }

    /// Makes the text of one of the side panes larger or smaller and remembers it.
    func resize(_ size: ReferenceWritableKeyPath<AppState, CGFloat>, _ key: String, by step: CGFloat) {
        self[keyPath: size] = min(max(self[keyPath: size] + step, 9), 30)
        UserDefaults.standard.set(Double(self[keyPath: size]), forKey: key)
        if key == "paneFontSize", !dictionaryQuery.isEmpty { lookUp(dictionaryQuery, log: false) }
    }

    /// Back to the text sizes the app starts with, in the reader and the three side panes.
    func resetFontSizes() {
        let d = UserDefaults.standard
        for (size, key, v) in [(\AppState.paneFontSize, "paneFontSize", CGFloat(15)), (\.sidebarFontSize, "sidebarFontSize", 13),
                               (\.resultsFontSize, "resultsFontSize", 14)] {
            self[keyPath: size] = v
            d.set(Double(v), forKey: key)
        }
        if !dictionaryQuery.isEmpty { lookUp(dictionaryQuery, log: false) }
        setFontSize(18)
    }

    func setFontSize(_ v: Double) {
        fontSize = min(max(v, 11), 40)
        UserDefaults.standard.set(fontSize, forKey: "fontSize")
        render(keepPlace: true)
    }

    /// `keepPlace` re-renders (other edition, font, line mode) and stays at the line being read.
    func render(scroll: Bool = false, keepPlace: Bool = false) {
        guard let ix = index, let ti = readerText else { return }
        let t = ix.texts[ti]
        let url = (sourceURL ?? URL(fileURLWithPath: ix.meta.sourcePath)).appendingPathComponent(t.path)
        var keepLbn: String? = nil
        if keepPlace, let r = rendered, let probe = topProbe { keepLbn = r.lbn(at: probe()) }
        if let p = pendingLbn { keepLbn = p; pendingLbn = nil }
        caretLbn = nil
        readerGeneration += 1
        let gen = readerGeneration
        let juan = readerJuan
        let opts = RenderOptions(edition: edition.isEmpty ? nil : edition, lineMode: lineStyle == .inline,
                                 lineBreaks: lineStyle == .lines, fontSize: CGFloat(fontSize))
        let focusDisp = self.focusDisp
        let focusQuiet = self.focusQuiet
        let focus = focusDisp == nil ? self.focus : nil
        let focusParts = self.focusParts
        let shared = compareLevels, sharedMin = ngramMin
        // gather the hits that fall inside this juan
        var marks: [Range<Int>] = []
        if result.kind == .hits, juan < t.juans.count {
            let a = t.searchStart + t.juans[juan].searchStart
            let b = juan + 1 < t.juans.count ? t.searchStart + t.juans[juan + 1].searchStart : t.searchEnd
            var i = firstHit(from: a)
            while i < result.hits.count, Int(result.hits[i].start) < b, marks.count < 4000 {
                marks += termSpans(result.hits[i]).map { ($0.lowerBound - t.searchStart)..<($0.upperBound - t.searchStart) }
                i += 1
            }
        }
        readerLoading = true
        readerQueue.async {
            var doc: ParsedDoc? = self.docCache.first(where: { $0.0 == t.id })?.1
            if doc == nil {
                doc = CBETAParser.parse(url: url)
                if let d = doc {
                    self.docCache.append((t.id, d))
                    if self.docCache.count > 3 { self.docCache.removeFirst() }
                }
            }
            let r = doc.map { renderJuan(doc: $0, juan: juan, options: opts, marks: marks, focus: focus, focusParts: focusParts, dispFocus: focusDisp, quietFocus: focusQuiet, shared: shared, sharedMin: sharedMin) }
            DispatchQueue.main.async {
                guard gen == self.readerGeneration else { return }
                self.readerLoading = false
                self.rendered = r
                self.renderVersion += 1
                self.updateMatchInfo()
                self.updateBookmarkedHere()
                if scroll, let f = r?.focus {
                    self.scrollAlignTop = false
                    self.scrollTo = f
                    self.scrollVersion += 1
                } else if let k = keepLbn, let line = r?.lineStarts.first(where: { $0.lbn == k }), line.loc > 0 {
                    self.scrollAlignTop = true
                    self.scrollTo = NSRange(location: line.loc, length: 0)
                    self.scrollVersion += 1
                } else {
                    self.scrollTo = nil
                }
                self.location = ""
                self.nearApp = nil
            }
        }
    }

    /// Editions offered for the text in the reader ("" = CBETA base text).
    var editionChoices: [String] {
        guard let ix = index, let ti = readerText else { return [""] }
        return [""] + ix.texts[ti].witnesses.filter { $0 != "【CB】" }
    }

    func stepEdition(_ d: Int) {
        let c = editionChoices
        guard c.count > 1, let i = c.firstIndex(of: edition) else { return }
        edition = c[(i + d + c.count) % c.count]
    }

    /// A variant was clicked in the text.
    func pickApp(_ id: Int) {
        bottomTab = .variants
        variantFollowPausedUntil = Date().addingTimeInterval(0.6)
        selectedApp = id
        variantScroller.show(id, settle: true)
    }

    /// A variant was chosen in the list: bring it into view in the text.
    func revealApp(_ id: Int) {
        guard let r = rendered, id < r.apps.count else { return }
        variantFollowPausedUntil = Date().addingTimeInterval(0.6)
        selectedApp = id
        variantScroller.show(id, settle: true)
        scrollAlignTop = false
        scrollTo = r.apps[id].range
        scrollVersion += 1
    }

    func caretMoved(_ loc: Int) {
        guard let ix = index, let ti = readerText, let r = rendered, let lbn = r.lbn(at: loc) else { return }
        let t = ix.texts[ti]
        let s = "\(t.id), p. \(prettyLbn(lbn))"
        if s != location { location = s }
        if caretLbn != lbn { caretLbn = lbn; saveLastPlace(); updateBookmarkedHere() }
        followVariants(at: loc)
    }

    /// The text was scrolled; `loc` is the character a third of the way down the visible area.
    func textScrolled(_ loc: Int) {
        // a scroll the app made itself to show a clicked variant must not move the pane off that variant
        let now = Date()
        if now < variantFollowPausedUntil || now.timeIntervalSince(lastFollow) < 0.2 { return }
        lastFollow = now
        followVariants(at: loc, settle: false)
    }

    /// Keeps the variants pane in step with the text: centres the variant nearest to `loc`.
    private func followVariants(at loc: Int, settle: Bool = true) {
        guard let r = rendered else { return }
        var best: Int? = nil
        var bestDist = Int.max
        for a in r.apps {
            let lo = a.range.location, hi = a.range.location + a.range.length
            let d = loc < lo ? lo - loc : (loc > hi ? loc - hi : 0)
            if d < bestDist { bestDist = d; best = a.id }
            if lo > loc && d > bestDist { break }
        }
        guard let near = best, near != nearApp else { return }
        nearApp = near
        // unless the caret is inside the variant just clicked, which stays centred
        if let sel = selectedApp, sel < r.apps.count,
           NSLocationInRange(loc, r.apps[sel].range) || loc == NSMaxRange(r.apps[sel].range) {
            variantScroller.show(sel, settle: settle)
        } else {
            variantScroller.show(near, settle: settle)
        }
    }
}
