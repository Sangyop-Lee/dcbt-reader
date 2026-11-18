import SwiftUI
import AppKit

struct DCBReaderApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("DCBT Reader", id: "main") {
            ContentView(layout: state.layout)
                .environmentObject(state)
                .frame(minWidth: 640, idealWidth: 1480, minHeight: 520, idealHeight: 900)
                .sheet(isPresented: $state.showTranslationSettings) { TranslationSettingsView().environmentObject(state) }
                .sheet(isPresented: $state.showDictionarySettings) { DictionarySettingsView().environmentObject(state) }
                .sheet(isPresented: $state.showComparePicker) { ComparePicker().environmentObject(state) }
                .sheet(isPresented: $state.showCitationSettings) { CitationSettingsView(settings: state.citation).environmentObject(state) }
        }
        .defaultSize(width: 1480, height: 900)
        .commands {
            CommandMenu("Display") {
                Button(state.showSidebar ? "Hide Filters and Texts Column" : "Show Filters and Texts Column") { state.toggle(.sidebar) }
                    .keyboardShortcut("1", modifiers: .command)
                Button(state.showResults ? "Hide Results Column" : "Show Results Column") { state.toggle(.results) }
                    .keyboardShortcut("2", modifiers: .command)
                Button(state.showReader ? "Hide Reader Column" : "Show Reader Column") { state.toggle(.reader) }
                    .keyboardShortcut("3", modifiers: .command)
                Button(state.showVariants ? "Hide Variant Readings" : "Show Variant Readings") { state.toggle(.variants) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Restore Default Column Sizes") { state.layout.reset() }
                Divider()
                ForEach(Theme.allCases) { t in
                    Button((state.theme == t ? "✓ " : "    ") + t.rawValue + " Background") { state.setTheme(t) }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Another DCBT Reader") {
                    // a second copy of the app, with its own window, for reading two texts side by side
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.createsNewApplicationInstance = true
                    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button("Translation Settings…") { state.showTranslationSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Dictionary Settings…") { state.showDictionarySettings = true }
                Button("Citation Format…") { state.showCitationSettings = true }
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy with Citation") { state.copyCitation() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(state.readerText == nil)
            }
            CommandMenu("Library") {
                Button("Rebuild Search Index") { state.rebuildIndex() }
                Divider()
                Button("Choose Source Texts Folder…") { state.chooseFolder(source: true) }
                Button("Choose SLR Folder…") { state.chooseFolder(source: false) }
                Button("Reload SLR Files") { state.reloadSLR(); state.filtersChanged() }
            }
            CommandMenu("Bookmarks") {
                Button(state.bookmarkedHere ? "Remove Bookmark at This Line" : "Bookmark This Line") { state.toggleBookmark() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(state.readerText == nil)
                Divider()
                BookmarkList(state: state)
            }
            CommandMenu("Reader") {
                Button("Back") { state.goBack() }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(state.backStack.isEmpty)
                Button("Forward") { state.goForward() }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(state.forwardStack.isEmpty)
                Divider()
                Button("Previous Juan") { state.setJuan(state.readerJuan - 1) }.keyboardShortcut("[", modifiers: .command)
                Button("Next Juan") { state.setJuan(state.readerJuan + 1) }.keyboardShortcut("]", modifiers: .command)
                Divider()
                Button("Next Edition") { state.stepEdition(1) }.keyboardShortcut("e", modifiers: .command)
                Button("Previous Edition") { state.stepEdition(-1) }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("CBETA Base Text") { state.edition = "" }.keyboardShortcut("b", modifiers: .command)
                ForEach(LineStyle.allCases) { l in
                    Button((state.lineStyle == l ? "✓ " : "    ") + l.rawValue) { state.setLineStyle(l) }
                }
                Button("Next Line-Number Style") {
                    let all = LineStyle.allCases
                    state.setLineStyle(all[((all.firstIndex(of: state.lineStyle) ?? 0) + 1) % all.count])
                }.keyboardShortcut("l", modifiers: .command)
                Divider()
                Button(state.goToMode ? "Search Box: Search" : "Search Box: Go to a Citation") { state.goToMode.toggle() }.keyboardShortcut("j", modifiers: .command)
                Divider()
                Button("Larger Text") { state.setFontSize(state.fontSize + 1) }.keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { state.setFontSize(state.fontSize - 1) }.keyboardShortcut("-", modifiers: .command)
            }
        }
    }
}

/// The saved places, as menu items; used in the menu bar and in the reader toolbar.
struct BookmarkList: View {
    @ObservedObject var state: AppState
    var body: some View {
        if state.bookmarks.isEmpty { Text("No bookmarks yet") }
        ForEach(state.bookmarks) { b in Button(b.label) { state.openBookmark(b) } }
        if !state.bookmarks.isEmpty {
            Divider()
            Menu("Remove Bookmark") {
                ForEach(state.bookmarks) { b in Button(b.label) { state.removeBookmark(b) } }
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var layout: PaneLayout

    var body: some View {
        VStack(spacing: 0) {
            if state.index == nil {
                LibrarySetupView()
            } else {
                SearchBar()
                Divider()
                GeometryReader { geo in
                    let w = geo.size.width
                    let showS = state.showSidebar, showR = state.showResults, showT = state.showReader
                    let minS: CGFloat = 180, minR: CGFloat = 190, minT: CGFloat = 350
                    let sW: CGFloat = !showS ? 0 : (showR || showT)
                        ? clampSize(layout.sidebar * w, minS, w - (showR ? minR : 0) - (showT ? minT : 0)) : w
                    let rW: CGFloat = !showR ? 0 : showT ? clampSize(layout.results * w, minR, w - sW - minT) : w - sW
                    HStack(spacing: 0) {
                        if showS {
                            Sidebar().frame(width: sW).background(Color(state.theme.panel))
                            if showR || showT {
                                SplitHandle(layout: layout, columns: true, current: { sW / w }) { start, dx in
                                    layout.sidebar = min(max(start + dx / w, 0.05), 0.8)
                                }
                                .background(Color(state.theme.panel))
                            }
                        }
                        if showR {
                            ResultsPane().frame(width: showT ? rW : nil).frame(maxWidth: showT ? nil : .infinity)
                                .background(Color(state.theme.background))
                            if showT {
                                SplitHandle(layout: layout, columns: true, current: { rW / w }) { start, dx in
                                    layout.results = min(max(start + dx / w, 0.05), 0.8)
                                }
                                .background(Color(state.theme.background))
                            }
                        }
                        if showT {
                            ReaderPane(layout: layout).frame(maxWidth: .infinity)
                                .background(Color(state.theme.background))
                        }
                    }
                }
                .overlay(alignment: .topLeading) { if state.showRecentSearches { RecentSearches() } }
                Divider()
                StatusBar()
            }
        }
        .background(Color(state.theme.panel))
        .preferredColorScheme(state.theme.isDark ? .dark : .light)
    }
}

// MARK: - First run

struct LibrarySetupView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 16) {
            Text("DCBT Reader").font(.largeTitle).bold()
            Text("Digitized Chinese Buddhist Text Reader").font(.title3).foregroundColor(.secondary)
            if let p = state.indexProgress {
                ProgressView(value: p).frame(width: 360)
                Text(state.libraryMessage).foregroundColor(.secondary)
                Text("This takes well under a minute and only happens once.").font(.callout).foregroundColor(.secondary)
            } else {
                Text(state.libraryMessage.isEmpty ? "No search index yet." : state.libraryMessage)
                    .foregroundColor(.secondary).multilineTextAlignment(.center)
                if let u = state.sourceURL { Text(u.path).font(.callout).foregroundColor(.secondary) }
                HStack {
                    Button("Choose Source Texts Folder…") { state.chooseFolder(source: true) }
                    if state.sourceURL != nil { Button("Build Index") { state.rebuildIndex() }.keyboardShortcut(.defaultAction) }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Text font for snippets and variant readings: falls back to CBETA's supplementary font for rare characters.
let rareCharacterFont = Font(GaijiStore.shared.font("PingFang TC", size: 14) as CTFont)

/// The pair of buttons that makes a pane's text smaller or larger.
struct TextSizeButtons: View {
    @EnvironmentObject var state: AppState
    let size: ReferenceWritableKeyPath<AppState, CGFloat>
    let key: String
    var body: some View {
        HStack(spacing: 6) {
            Button { state.resize(size, key, by: -1) } label: { Image(systemName: "textformat.size.smaller") }.help("Smaller text in this pane")
            Button { state.resize(size, key, by: 1) } label: { Image(systemName: "textformat.size.larger") }.help("Larger text in this pane")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Search bar

/// The last searches, shown under the search box while it has just been clicked.
struct RecentSearches: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.recentSearches, id: \.self) { q in
                Button {
                    state.query = q
                    state.goToMode = state.recentCitations.contains(q)
                    state.runSearch()
                } label: {
                    Text(q).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 3)
            Button {
                state.showRecentSearches = false
                ActivityLog.searches.open()
            } label: {
                Label("All past searches…", systemImage: "tray.full").foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(.leading, 12).padding(.top, 2)
    }
}

struct SearchBar: View {
    @EnvironmentObject var state: AppState

    var prompt: String {
        state.goToMode ? "A citation — T 2145: 55.63b20 · T55n2145_p0063b20 · X 30, no. 600, p. 8b12 · T2145 卷14"
            : state.byMeaning ? "Describe or paste a passage — finds passages similar in meaning"
            : "Search — 菩薩 般若 · 色?是空 · 如來*法身"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("", selection: $state.goToMode) {
                    Text("Search").tag(false)
                    Text("Go to").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                .help("Search: look for the words typed. Go to: open the place a citation names, such as T 2145: 55.63b20 (⌘J)")
                SearchField(placeholder: prompt, text: $state.query, onSubmit: { state.runSearch() },
                            onRecent: { show in
                                let on = show && !state.recentSearches.isEmpty
                                if state.showRecentSearches != on { state.showRecentSearches = on }
                            })
                    .frame(height: 24)

                Toggle(isOn: $state.byMeaning) { Label("By meaning", systemImage: "sparkles") }
                    .toggleStyle(.button)
                    .help("Semantic search: find passages similar in meaning to what you typed, instead of the exact characters")
                    .onChange(of: state.byMeaning) { if state.byMeaning { state.loadSemantics() }; state.runSearch() }
                    .disabled(state.goToMode)
                Button(state.goToMode ? "Go" : "Search") { state.runSearch() }
                    .keyboardShortcut(.defaultAction)
                if state.searching { ProgressView().controlSize(.small) }
                Button { state.showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $state.showHelp, arrowEdge: .bottom) { HelpView() }
                Divider().frame(height: 18)
                ColumnButton(column: .sidebar, icon: "sidebar.left", name: "filters and texts column")
                ColumnButton(column: .results, icon: "list.bullet.rectangle", name: "results column")
                ColumnButton(column: .reader, icon: "book", name: "reader column")
                ColumnButton(column: .variants, icon: "rectangle.bottomthird.inset.filled", name: "variant readings")
                Button { state.layout.reset() } label: { Image(systemName: "arrow.counterclockwise").foregroundColor(.secondary) }
                    .buttonStyle(.borderless)
                    .help("Restore the default column and pane sizes")
                Menu {
                    ForEach(Theme.allCases) { t in
                        Button { state.setTheme(t) } label: {
                            if state.theme == t { Label(t.rawValue, systemImage: "checkmark") } else { Text(t.rawValue) }
                        }
                    }
                } label: { Image(systemName: "paintpalette") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Background colour")
            }
            if !state.goToMode && state.mode == .proximity {
                HStack(spacing: 14) {
                    Stepper(value: $state.distance, in: 0...500, step: 5) {
                        HStack(spacing: 4) {
                            Text("At most")
                            TextField("", value: $state.distance, formatter: NumberFormatter()).frame(width: 46)
                                .onSubmit { state.runSearch() }
                            Text("other characters between the terms")
                        }
                    }
                    .onChange(of: state.distance) { state.runSearch() }
                    Toggle("Terms in this order", isOn: $state.ordered).onChange(of: state.ordered) { state.runSearch() }
                }
                .font(.callout)
            }
            if !state.goToMode && state.mode != .semantic && (state.query.contains("*") || state.query.contains("＊")) {
                Stepper(value: $state.maxStar, in: 1...100) {
                    Text("* stands for up to \(state.maxStar) characters")
                }
                .font(.callout)
                .onChange(of: state.maxStar) { state.runSearch() }
                .fixedSize()
            }
            if !state.goToMode && state.mode == .semantic {
                HStack(spacing: 10) {
                    if state.semBuilding {
                        ProgressView(value: state.semProgress).frame(width: 160)
                        Text(state.semStatus).lineLimit(1).truncationMode(.middle)
                        Button("Stop") { state.cancelSemantic() }
                    } else {
                        Picker("Passages", selection: Binding(get: { state.allSizes ? "all" : state.passageSize.rawValue }, set: { v in
                            state.setPassages(PassageSize(rawValue: v))
                        })) {
                            ForEach(PassageSize.allCases) { Text($0.label).tag($0.rawValue) }
                            Text("All").tag("all")
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .help("How much text each result holds. Small: \(PassageSize.small.explanation). Medium: \(PassageSize.medium.explanation). Large: \(PassageSize.large.explanation). All searches the three sizes together and keeps the best passage where they overlap. Each size has its own index.")
                        if state.allSizes {
                            // each size has its own index: show how far each has got
                            Text("Indexed: " + PassageSize.allCases.map {
                                "\($0.label) \(state.semCoverage[$0] ?? 0)" }.joined(separator: " · "))
                                .lineLimit(1)
                        } else {
                            Text("Indexed: \(state.semIndexedInScope)").lineLimit(1)
                        }
                        Button("Build for Texts in Scope") { state.buildSemantic() }
                            .disabled(state.allSizes ? PassageSize.allCases.allSatisfy { (state.semCoverage[$0] ?? 0) >= state.scopeCount }
                                                     : state.semIndexedInScope >= state.scopeCount)
                            .help("Reads every passage of the texts in scope with the language model and stores the result. Searching by meaning only covers texts that have been read this way. A single sūtra takes seconds and an SLR group minutes; the whole Taishō and Xuzangjing take about 5 hours and 1.4 GB at Large, more at the smaller sizes.")
                        if !state.semStatus.isEmpty { Text(state.semStatus).foregroundColor(.orange) }
                    }
                }
                .font(.callout)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct ColumnButton: View {
    @EnvironmentObject var state: AppState
    let column: Column
    let icon: String
    let name: String
    var body: some View {
        let on = state.isShown(column)
        Button { state.toggle(column) } label: {
            Image(systemName: icon).foregroundColor(on ? .accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help((on ? "Hide the " : "Show the ") + name)
    }
}

struct HelpView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search help").font(.headline)
            Group {
                Text("**One search field.** A single term finds the exact characters, ignoring punctuation and line breaks.")
                Text("**Several terms separated by spaces** find places where all of them occur close together. Under the field you set how many other characters may stand between them, and whether they must keep their order.")
                Text("**Wildcards**: `?` is exactly one character, `*` is any run of characters (0 up to the limit shown under the field). Example: `色?是空`, `如來*涅槃`.")
                Text("**Go to a citation**: switch the menu before the search box from Search to Go to, type a Taishō or Xuzangjing reference and press Return; the reader opens at that line. Most ways of writing one are understood: `T 2145: 55.63b20–22`, `T. 2059 [L] 358a11`, `T 45, no. 1853, p. 42a23`, `T55, 61b9`, `T55n2145_p0063b20`, `X 30, no. 600, p. 8b12`, `大正藏55冊63頁中`. A bare number (`T 2145`) opens the text, and a fascicle can be added: `T2145 vol 14`, `T2145 juan 14`, `T2145 卷14`, `T2145 14권`. A whole footnote can be pasted; reading starts where the canon is named.")
                Text("**By meaning** (the button beside the field) looks for passages similar in meaning to what you typed, using \(state.semanticModelName). Works best with a phrase or a whole sentence.")
                Text("**In the reader**, the up and down arrows in the toolbar above the text jump to the previous or next match in the text being read (⇧⌘G, ⌘G), across juan.")
                Text("**Bookmarks**: the bookmark button above the text (⌘D) saves the line the cursor is on, or the first line on screen; the list button beside it, and the Bookmarks menu, jump back to a saved line. The app also reopens at the text and place you were reading when you quit.")
                Text("**Results**: with a result selected, the up and down arrow keys move to the previous or next one.")
                Text("**Dictionary and translation**: select up to four characters in the text to look them up in your dictionaries (chosen in Dictionary Settings); select five or more and press Translate in the Translation tab to translate them into Korean or English. Translation uses your own OpenAI, Anthropic or Google API key, set in Translation Settings (⌘,).")
                Text("**Copy with citation** (⇧⌘C, the quotation-mark button, or right-click a selection) copies the selected passage as the Taishō or Xuzangjing prints it, with its title, fascicle, chapter headings as printed (every level, when they are nested), place and the variant readings. Citation Format… lets you rearrange the pieces by dragging, choose how each is written, and pick the editions reported.")
                Text("**Logs**: clicking the search box lists your last 20 searches; choose one to run it again. Every search, dictionary lookup and translation is also written to a log, opened from that list and from the tray buttons in the Dictionary and Translation tabs.")
                Text("**Comparing two texts**: the overlapping-rectangles button above the text (or a right-click on a text in the list) compares the text being read with another. Runs of characters both texts have are tinted, faintly for three characters and more strongly up to eight or more; the menu beside it sets the shortest run shown. Pointing at a tinted passage boxes the longest passage shared at that spot, and clicking it searches the other text for it. The button with the other text's title goes to that text at the passage it shares with the place you were reading, and the same button there comes back. File ▸ Open Another DCBT Reader (⌘N) opens a second window for reading the two side by side.")
                Text("**Back and forward**: the two arrows in front of the juan menu (⌥⌘←, ⌥⌘→) return to the place you were reading before a jump, whether in this text or another, and forward again. Juan are changed with the menu or ⌘[ and ⌘].")
                Text("**Line numbers**: the numbered-list button offers running text, line numbers inside the text, or one printed line per row.")
                Text("**Rare characters** that are not in Unicode are shown with CBETA's own glyph images; hold the pointer over one to see its CBETA number and composition.")
                Text("**Limit search** (left column) restricts every search to an SLR group, a title, an author or translator, an era, or only the current text (the one open in the reader). With an empty search field the left column lists the texts that match, as a catalogue.")
                Text("**Layout**: the four buttons at the top right hide or show each column and the variants pane (⌘1–⌘4); the palette button changes the background colour.")
                Text("**Editions**: in the reader, a blue underline marks places where editions differ. Pick an edition to read its text; all variants are listed in the pane below the text.")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 440)
    }
}

// MARK: - Sidebar: scope + texts

struct Sidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Limit search").font(.headline)
                    Spacer()
                    if !state.filter.isUnrestricted {
                        Button("Clear") { state.clearFilters() }.buttonStyle(.link)
                    }
                    TextSizeButtons(size: \.sidebarFontSize, key: "sidebarFontSize")
                }
                Picker("SLR group", selection: $state.selectedSLR) {
                    Text("None (all texts)").tag("")
                    ForEach(state.slrFiles) { f in Text("\(f.name) (\(f.ids.count))").tag(f.id) }
                }
                .onChange(of: state.selectedSLR) { state.filtersChanged() }
                if !state.slrMissing.isEmpty {
                    Text("\(state.slrMissing.count) entries of this group are not in the library: \(state.slrMissing.joined(separator: ", "))")
                        .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
                TextField("Title or number (e.g. 法華, T0262)", text: $state.titleFilter)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: state.titleFilter) { state.filtersChanged() }
                TextField("Author / translator (e.g. 竺法護)", text: $state.authorFilter)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: state.authorFilter) { state.filtersChanged() }
                Picker("Era", selection: $state.eraFilter) {
                    Text("Any era").tag("")
                    ForEach(state.eras, id: \.name) { e in Text("\(e.name) (\(e.count))").tag(e.name) }
                }
                .onChange(of: state.eraFilter) { state.filtersChanged() }
                Toggle("Search only the current text", isOn: $state.onlyCurrentText)
                .disabled(state.readerText == nil)
                .help("Search only in the text open in the reader. The other limits above are ignored while this is on.")
                .onChange(of: state.onlyCurrentText) { state.filtersChanged() }
                Text(state.scopeCount == 1 ? "1 text in scope" : "\(state.scopeCount) texts in scope").font(.caption).foregroundColor(.secondary)
            }
            .padding(12)
            Divider()
            HStack {
                Text("Texts").font(.headline).lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                if state.result.kind != .catalog {
                    Picker("", selection: $state.sortByCount) {
                        Text("Canon order").tag(false)
                        Text("Most hits").tag(true)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            TextList()
        }
    }
}

struct TextList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let groups = state.sortedGroups
        List(selection: Binding(get: { state.selectedText ?? -1 }, set: { v in state.selectText(v < 0 ? nil : v) })) {
            if state.result.kind != .catalog {
                HStack {
                    Text("All texts").bold()
                    Spacer()
                    Text("\(state.result.total)").foregroundColor(.secondary).monospacedDigit()
                }
                .tag(-1)
            }
            ForEach(groups) { g in
                TextRow(group: g, showCount: state.result.kind != .catalog).tag(g.ti)
                    .contextMenu {
                        Button("Compare with the Text Being Read") { state.compare(with: g.ti) }
                            .disabled(state.readerText == nil || state.readerText == g.ti)
                    }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

struct TextRow: View {
    @EnvironmentObject var state: AppState
    let group: TextGroup
    let showCount: Bool

    var body: some View {
        if let ix = state.index {
            let t = ix.texts[group.ti]
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title.isEmpty ? t.id : t.title).font(.system(size: state.sidebarFontSize)).lineLimit(1)
                    Text("\(t.id)\(t.author.isEmpty ? "" : " · " + t.author)")
                        .font(.system(size: state.sidebarFontSize - 3)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if showCount { Text("\(group.count)").font(.system(size: state.sidebarFontSize)).foregroundColor(.secondary).monospacedDigit() }
            }
        }
    }
}

// MARK: - Results

struct ResultsPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if state.result.kind == .catalog {
                VStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass").font(.system(size: 34)).foregroundColor(.secondary)
                    Text("Type a search above").font(.title3)
                    Text("or pick a text on the left to read it.").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.rows.isEmpty {
                Text(state.searching ? "Searching…" : "No results.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack { Spacer(); TextSizeButtons(size: \.resultsFontSize, key: "resultsFontSize") }
                    .padding(.horizontal, 10).padding(.top, 6)
                ScrollViewReader { proxy in
                List(selection: Binding(get: { state.selectedRow ?? -1 }, set: { v in
                    state.selectedRow = v < 0 ? nil : v
                    if v >= 0 { state.openRow(v) }
                })) {
                    ForEach(state.rows, id: \.self) { r in
                        HitRow(row: r).tag(r)
                    }
                    if state.rowTotal > state.rows.count {
                        Button("Show more (\(state.rows.count) of \(state.rowTotal) shown)") { state.showMore() }
                            .buttonStyle(.link)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onChange(of: state.selectedRow) { _, v in if let v = v { proxy.scrollTo(v) } }
                }
            }
        }
    }
}

struct HitRow: View {
    @EnvironmentObject var state: AppState
    let row: Int

    var body: some View {
        if let ix = state.index, let s = state.snippet(row: row) {
            let t = ix.texts[s.textIndex]
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(t.title).font(.system(size: state.resultsFontSize - 3)).bold().lineLimit(1)
                    Text("\(t.id) · 卷\(t.juans[min(s.juan, t.juans.count - 1)].n) · p. \(prettyLbn(s.lbn))")
                        .font(.system(size: state.resultsFontSize - 3)).foregroundColor(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if state.result.kind == .semantic, row < state.result.sem.count {
                        Text("\(Int((state.result.sem[row].score * 100).rounded()))%")
                            .font(.caption).monospacedDigit().foregroundColor(.secondary)
                    }
                }
                Text(s.segs.reduce(into: AttributedString()) { acc, seg in
                    var piece = AttributedString(seg.text)
                    if seg.hit { piece.foregroundColor = .red; piece.inlinePresentationIntent = .stronglyEmphasized }
                    acc += piece
                })
                .font(Font(GaijiStore.shared.font("PingFang TC", size: state.resultsFontSize) as CTFont))
                .lineLimit(state.result.kind == .semantic ? 3 : 2)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Reader

struct ReaderPane: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var layout: PaneLayout

    var body: some View {
        if let ix = state.index, let ti = state.readerText {
            let t = ix.texts[ti]
            GeometryReader { geo in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(t.title).font(.title3).bold().lineLimit(1)
                            Text(t.id).foregroundColor(.secondary)
                            Spacer()
                            if state.readerLoading { ProgressView().controlSize(.small) }
                            Button { state.toggleBookmark() } label: {
                                Image(systemName: state.bookmarkedHere ? "bookmark.fill" : "bookmark")
                            }
                            .help(state.bookmarkedHere ? "Remove the bookmark at this line (⌘D)" : "Bookmark this line (⌘D)")
                            Menu {
                                BookmarkList(state: state)
                            } label: { Image(systemName: "list.star") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Bookmarks")
                            HStack(spacing: 6) {
                                Button { state.setFontSize(state.fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                                    .help("Smaller text")
                                Button { state.setFontSize(state.fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                                    .help("Larger text")
                                Button { state.resetFontSizes() } label: { Image(systemName: "arrow.counterclockwise") }
                                    .help("Restore the default text size in every pane")
                            }
                            .buttonStyle(.borderless)
                        }
                        if !t.author.isEmpty { Text(t.author).font(.callout).foregroundColor(.secondary).lineLimit(1) }
                        // one row when there is room, two when the column is narrow
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                ReaderNavBar(t: t)
                                ReaderToolsBar(divider: true)
                                Spacer(minLength: 0)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) { ReaderNavBar(t: t); Spacer(minLength: 0) }
                                HStack(spacing: 8) { ReaderToolsBar(divider: false); Spacer(minLength: 0) }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    Divider()
                    ReaderTextView(background: state.theme.background, rendered: state.rendered, version: state.renderVersion,
                                   scrollTo: state.scrollTo, scrollVersion: state.scrollVersion,
                                   alignTop: state.scrollAlignTop,
                                   registerTopProbe: { state.topProbe = $0 },
                                   onApp: { id in state.pickApp(id) },
                                   onLocation: { loc in state.caretMoved(loc) },
                                   onScroll: { loc in state.textScrolled(loc) },
                                   onSelection: { text in state.selectionChanged(text) },
                                   onRange: { r in state.selectionRange = r },
                                   onCopyCitation: { state.copyCitation() },
                                   onHover: { loc in state.sharedPassage(at: loc)?.attr },
                                   onPassageClick: { loc in state.searchShared(at: loc) })
                }
                .frame(maxHeight: .infinity)
                if state.showVariants {
                    let h = geo.size.height
                    let bH = clampSize(layout.bottom * h, 90, h - 220)
                    SplitHandle(layout: layout, columns: false, current: { bH / h }) { start, dy in
                        layout.bottom = min(max(start - dy / h, 0.05), 0.8)
                    }
                    .background(Color(state.theme.panel))
                    BottomPane().frame(height: bH)
                        .background(Color(state.theme.panel))
                }
            }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "book").font(.system(size: 34)).foregroundColor(.secondary)
                Text("Select a result or a text to read it here.").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Juan and edition controls of the reader toolbar.
struct ReaderNavBar: View {
    @EnvironmentObject var state: AppState
    let t: TextInfo
    var body: some View {
        HStack(spacing: 8) {
            Button { state.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(state.backStack.isEmpty).help("Back to the place you were reading before, in this text or another (⌥⌘←)")
            Button { state.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(state.forwardStack.isEmpty).help("Forward again (⌥⌘→)")
            Picker("", selection: Binding(get: { state.readerJuan }, set: { state.setJuan($0) })) {
                ForEach(Array(t.juans.enumerated()), id: \.offset) { i, j in Text("卷 \(j.n)").tag(i) }
            }
            .labelsHidden().fixedSize()
            Text("Edition").foregroundColor(.secondary).padding(.leading, 6).fixedSize()
            Picker("", selection: $state.edition) {
                Text("CBETA").tag("")
                ForEach(t.witnesses.filter { $0 != "【CB】" }, id: \.self) { w in Text(w).tag(w) }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: state.edition) { state.render(keepPlace: true) }
        }
    }
}

/// Line-number switch and match arrows of the reader toolbar.
struct ReaderToolsBar: View {
    @EnvironmentObject var state: AppState
    let divider: Bool
    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(LineStyle.allCases) { l in
                    Button { state.setLineStyle(l) } label: {
                        if state.lineStyle == l { Label(l.rawValue, systemImage: "checkmark") } else { Text(l.rawValue) }
                    }
                }
            } label: { Image(systemName: "list.number") }
            .menuStyle(.borderedButton)
            .fixedSize()
            .help("Line numbers of the edition: none, inside the running text, or one printed line per row")
            Menu {
                Button("Copy with Citation") { state.copyCitation() }
                Button("Citation Format…") { state.showCitationSettings = true }
                if !state.citation.saved.isEmpty {
                    Divider()
                    ForEach(state.citation.saved) { s in
                        Button((state.citation.name == s.name ? "✓ " : "    ") + s.name) { state.citation.use(s.format, named: s.name) }
                    }
                }
            } label: { Image(systemName: "quote.opening") } primaryAction: { state.copyCitation() }
            .menuStyle(.borderedButton)
            .fixedSize()
            .help("Copy the selected passage with its citation and variant readings (⇧⌘C); the arrow opens the citation format")
            CompareBar()
            let mp = state.matchInfo
            if mp.total > 0 {
                if divider { Divider().frame(height: 16) }
                Button { state.stepMatch(-1) } label: { Image(systemName: "chevron.up") }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help("Previous match in this text (⇧⌘G)")
                Button { state.stepMatch(1) } label: { Image(systemName: "chevron.down") }
                    .keyboardShortcut("g", modifiers: .command)
                    .help("Next match in this text (⌘G)")
                Text(mp.pos > 0 ? "\(mp.pos) / \(mp.total)" : "\(mp.total)")
                    .font(.callout).monospacedDigit().foregroundColor(.secondary).fixedSize()
                    .help(mp.pos > 0 ? "Match \(mp.pos) of \(mp.total) in this text" : "\(mp.total) matches in this text")
            }
        }
    }
}

/// The pane under the text: variant readings, dictionary, translation.
struct BottomPane: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $state.bottomTab) {
                    ForEach(BottomTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                switch state.bottomTab {
                case .variants:
                    Text("\(state.rendered?.apps.count ?? 0) in this juan").foregroundColor(.secondary).lineLimit(1)
                    if !state.edition.isEmpty {
                        Text("Showing \(state.edition), in red in the text.").font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                case .dictionary:
                    Text(state.dictionaryQuery.isEmpty ? "Select up to four characters in the text" : state.dictionaryQuery)
                        .foregroundColor(.secondary).lineLimit(1)
                    Button { state.showDictionarySettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Dictionary settings: choose which dictionaries to use")
                    Button { ActivityLog.dictionary.open() } label: { Image(systemName: "tray.full") }
                        .buttonStyle(.borderless).help("Open the log of past dictionary lookups")
                case .translation:
                    Picker("", selection: $state.translationLanguage) {
                        ForEach(TranslationLanguage.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: state.translationLanguage) { state.saveTranslationSettings() }
                    Button("Translate") { state.translate() }
                        .disabled(state.translationSource.isEmpty || state.translating)
                    if state.translating { ProgressView().controlSize(.small) }
                    Button { state.showTranslationSettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Translation settings: company, API key and model")
                    Button { if !ActivityLog.translations.open() { state.translationError = "No translations have been logged yet." } } label: { Image(systemName: "tray.full") }
                        .buttonStyle(.borderless).help("Open the log of past translations")
                }
                Spacer(minLength: 0)
                TextSizeButtons(size: \.paneFontSize, key: "paneFontSize")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            switch state.bottomTab {
            case .variants: VariantsPane(scroller: state.variantScroller)
            case .dictionary: DictionaryPane()
            case .translation: TranslationPane()
            }
        }
    }
}

struct DictionaryPane: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if state.dictionaries.isEmpty {
            VStack(spacing: 8) {
                if state.dictionariesLoading {
                    Text(state.dictionaryStatus.isEmpty ? "Loading the dictionaries…" : state.dictionaryStatus)
                } else if state.dictionarySources.isEmpty {
                    Text("No dictionary found. Put a StarDict dictionary (its files or the archive you downloaded) or a Babylon .bgl file in the Dictionaries folder beside the app. The README explains.")
                    Button("Dictionary Settings…") { state.showDictionarySettings = true }
                } else {
                    Text("All dictionaries are switched off, or none could be read.")
                    Button("Dictionary Settings…") { state.showDictionarySettings = true }
                }
            }
            .multilineTextAlignment(.center).foregroundColor(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.dictionaryArticles.isEmpty {
            Text(state.dictionaryQuery.isEmpty ? "Select up to four characters in the text to look them up."
                                              : "No entry for \(state.dictionaryQuery) in \(state.dictionaries.count == 1 ? state.dictionaries[0].name : "the \(state.dictionaries.count) dictionaries").")
                .foregroundColor(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(state.dictionaryArticles) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(a.word).font(state.paneFont("Songti TC Bold", 5))
                                Text(a.dictionary).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                            Text(a.body).textSelection(.enabled).lineSpacing(4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .id(state.dictionaryQuery)
            // a cross-reference inside an article looks that word up
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "dcbt-dictionary",
                      let w = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "w" })?.value else { return .systemAction }
                state.lookUp(w)
                return .handled
            })
        }
    }
}

struct DictionarySettingsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dictionary Settings").font(.title3).bold()
            Text("Dictionaries in the Dictionaries folder beside the app. Tick the ones to use; a selection of up to four characters is looked up in each of them, in this order. The arrows move a dictionary up or down.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if state.dictionarySources.isEmpty {
                Text("The folder has no dictionaries yet. Add a StarDict dictionary (.ifo, .idx and .dict or .dict.dz, or the archive they came in: .tar.bz2, .tbz, .trz, .zip …) or a Babylon .bgl file, then press Rescan.")
                    .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.dictionarySources) { s in
                            let loaded = state.dictionaries.first { $0.sourceId == s.id }
                            HStack(spacing: 6) {
                            Toggle(isOn: Binding(get: { !state.dictionaryOff.contains(s.id) }, set: { state.setDictionary(s.id, on: $0) })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(loaded?.name ?? s.url.lastPathComponent).lineLimit(1)
                                    Text(s.id + " · " + s.kindLabel + (loaded.map { " · \($0.count) entries" } ?? "")
                                         + (state.dictionaryFailed.contains(s.id) ? " · could not be read" : ""))
                                        .font(.caption).foregroundColor(state.dictionaryFailed.contains(s.id) ? .orange : .secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            Button { state.moveDictionary(s.id, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(s.id == state.dictionarySources.first?.id).help("Show this dictionary's results earlier")
                            Button { state.moveDictionary(s.id, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(s.id == state.dictionarySources.last?.id).help("Show this dictionary's results later")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
            if state.dictionariesLoading {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(state.dictionaryStatus.isEmpty ? "Loading…" : state.dictionaryStatus).font(.callout).foregroundColor(.secondary) }
            }
            HStack {
                Button("Open Dictionaries Folder") { state.openDictionariesFolder() }
                Button("Rescan") { state.loadDictionaries() }
                Spacer()
                Button("Done") { state.showDictionarySettings = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct TranslationPane: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if state.translationSource.isEmpty {
            Text("Select five or more characters in the text to translate them.")
                .foregroundColor(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.translationSource).font(state.paneFont("PingFang TC", -1)).foregroundColor(.secondary).lineLimit(3)
                    if !state.translationError.isEmpty {
                        Text(state.translationError).foregroundColor(.orange).textSelection(.enabled)
                    } else if state.translating {
                        Text("Translating…").foregroundColor(.secondary)
                    } else if state.translationResult.isEmpty {
                        Text("Press Translate.").foregroundColor(.secondary)
                    } else {
                        Text(state.translationResult).font(Font.system(size: state.paneFontSize)).lineSpacing(4).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
    }
}

struct TranslationSettingsView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var form = TranslationForm()

    var body: some View {
        let p = state.translationProvider
        VStack(alignment: .leading, spacing: 14) {
            Text("Translation Settings").font(.title3).bold()
            Text("Selected passages are sent to the company you choose for translation (OpenAI, Anthropic or Google), using your own API key. Keys are kept in this Mac's keychain, one for each company.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Company").frame(width: 90, alignment: .leading)
                Picker("", selection: Binding(get: { state.translationProvider }, set: { state.setTranslationProvider($0); form.models = []; form.message = "" })) {
                    ForEach(TranslationProvider.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack {
                Text("API key").frame(width: 90, alignment: .leading)
                SecureField("\(p.keyName) (\(p.keyHint))", text: Binding(get: { form.keys[p] ?? "" }, set: { form.keys[p] = $0 }))
            }
            HStack {
                Text("Model").frame(width: 90, alignment: .leading)
                TextField(p.modelHint, text: $state.translationModel)
                if !form.models.isEmpty {
                    Picker("", selection: $state.translationModel) {
                        ForEach(form.models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 190)
                }
                Button(form.loading ? "Loading…" : "List Models") { form.fetch(p) }.disabled((form.keys[p] ?? "").isEmpty || form.loading)
            }
            if !form.message.isEmpty { Text(form.message).font(.callout).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Translate into").frame(width: 90, alignment: .leading)
                Picker("", selection: $state.translationLanguage) {
                    ForEach(TranslationLanguage.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack {
                Spacer()
                Button("Cancel") { state.loadTranslationSettings(); state.showTranslationSettings = false }
                Button("Save") {
                    for q in TranslationProvider.allCases { KeyStore.save(form.keys[q] ?? "", for: q) }
                    state.saveTranslationSettings()
                    state.showTranslationSettings = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580)
    }
}

final class TranslationForm: ObservableObject {
    @Published var keys: [TranslationProvider: String] = Dictionary(uniqueKeysWithValues: TranslationProvider.allCases.map { ($0, KeyStore.load($0)) })
    @Published var models: [String] = []
    @Published var loading = false
    @Published var message = ""

    func fetch(_ p: TranslationProvider) {
        loading = true
        message = ""
        Translator.models(p, key: (keys[p] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) { result in
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let ids): self.models = ids; if ids.isEmpty { self.message = "No models were listed for this key." }
                case .failure(let e): self.message = e.localizedDescription
                }
            }
        }
    }
}

struct VariantsPane: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var scroller: VariantScroller

    var body: some View {
        let apps = state.rendered?.apps ?? []
        VStack(alignment: .leading, spacing: 0) {
            if apps.isEmpty {
                Text(state.rendered == nil ? "" : "No variants are recorded for this juan.")
                    .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: Binding(get: { state.selectedApp ?? -1 }, set: { v in if v >= 0 { state.revealApp(v) } })) {
                        ForEach(apps) { a in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(prettyLbn(a.lbn)).font(.caption).monospacedDigit().foregroundColor(.secondary)
                                    .frame(width: 58, alignment: .leading)
                                Text(a.summary).font(state.paneFont("PingFang TC", -1)).lineLimit(3)
                                if !a.entry.lemWits.isEmpty {
                                    Spacer(minLength: 4)
                                    Text("base: " + a.entry.lemWits.joined()).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            .tag(a.id)
                            .id(a.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .onChange(of: scroller.version) {
                        guard let v = scroller.target else { return }
                        proxy.scrollTo(v, anchor: .center)
                        if scroller.settle {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { proxy.scrollTo(v, anchor: .center) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack {
            Text(state.status).lineLimit(1)
            Spacer()
            Text(state.location).monospacedDigit()
                .textSelection(.enabled)
        }
        .font(.callout)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}
