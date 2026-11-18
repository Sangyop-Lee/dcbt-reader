import Foundation
import AppKit

/// A saved place in a text: text id, juan and the page-column-line it starts at.
struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var textId: String
    var title: String
    var juan: Int
    var lbn: String             // "0063b20"
    var excerpt: String = ""    // the first characters of that line
    var added = Date()

    var label: String { "\(title) · \(textId), p. \(prettyLbn(lbn))" + (excerpt.isEmpty ? "" : "  \(excerpt)") }
}

extension CorpusIndex {
    /// Global index of the line of a text with this page-column-line number.
    func lineIndex(text ti: Int, lbn: String) -> Int? {
        let t = texts[ti]
        let key = packLbn(lbn)
        for li in t.firstLine..<(t.firstLine + t.lineCount) where lines[li].lbn == key { return li }
        return nil
    }
}

extension AppState {
    private static var bookmarksURL: URL { AppPaths.supportDir.appendingPathComponent("bookmarks.json") }

    func loadBookmarks() {
        guard let d = try? Data(contentsOf: AppState.bookmarksURL),
              let b = try? JSONDecoder().decode([Bookmark].self, from: d) else { return }
        bookmarks = b
    }

    private func saveBookmarks() {
        try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(bookmarks) { try? d.write(to: AppState.bookmarksURL, options: .atomic) }
    }

    /// The place being read: the line the caret is on, or else the first line on screen.
    func currentPlace() -> (ti: Int, juan: Int, lbn: String)? {
        guard let ti = readerText, let r = rendered else { return nil }
        if let l = caretLbn { return (ti, readerJuan, l) }
        if let probe = topProbe, let l = r.lbn(at: probe()) { return (ti, readerJuan, l) }
        return (ti, readerJuan, r.lineStarts.first?.lbn ?? "")
    }

    /// The bookmark at the current place, if there is one.
    var bookmarkHere: Bookmark? {
        guard let ix = index, let p = currentPlace() else { return nil }
        let id = ix.texts[p.ti].id
        return bookmarks.first { $0.textId == id && $0.lbn == p.lbn }
    }

    func updateBookmarkedHere() {
        let v = bookmarkHere != nil
        if v != bookmarkedHere { bookmarkedHere = v }
    }

    /// Adds a bookmark at the current place, or removes the one already there.
    func toggleBookmark() {
        guard let ix = index, let p = currentPlace() else { return }
        defer { updateBookmarkedHere() }
        if let b = bookmarkHere { removeBookmark(b); return }
        let t = ix.texts[p.ti]
        var excerpt = ""
        if let li = ix.lineIndex(text: p.ti, lbn: p.lbn) {
            let a = Int(ix.lines[li].dispStart)
            let b = li + 1 < t.firstLine + t.lineCount ? Int(ix.lines[li + 1].dispStart) : t.dispEnd
            excerpt = String(ix.displayString(a, min(b, a + 24)).prefix(14))
        }
        loadBookmarks()     // another running copy of the app may have added some
        bookmarks.insert(Bookmark(textId: t.id, title: t.title, juan: p.juan, lbn: p.lbn, excerpt: excerpt), at: 0)
        saveBookmarks()
        status = "Bookmarked \(t.title), p. \(prettyLbn(p.lbn))."
    }

    func removeBookmark(_ b: Bookmark) {
        loadBookmarks()
        bookmarks.removeAll { $0.id == b.id }
        saveBookmarks()
        updateBookmarkedHere()
        status = "Removed the bookmark at \(b.title), p. \(prettyLbn(b.lbn))."
    }

    func openBookmark(_ b: Bookmark) {
        guard let ix = index, let ti = ix.textIndexById[b.textId] else {
            status = "\(b.title) (\(b.textId)) is not in the library any more."
            return
        }
        openPlace(text: ti, juan: b.juan, lbn: b.lbn, highlight: true)
        status = b.label
    }

    /// Opens a text at a line without touching the search results.
    func openPlace(text ti: Int, juan: Int, lbn: String, highlight: Bool) {
        guard let ix = index else { return }
        let t = ix.texts[ti]
        if highlight, let li = ix.lineIndex(text: ti, lbn: lbn) {
            let s = Int(ix.lines[li].searchStart)
            let e = li + 1 < t.firstLine + t.lineCount ? Int(ix.lines[li + 1].searchStart) : t.searchEnd
            openReader(text: ti, juan: ix.juanIndex(at: s, text: ti), focus: (s - t.searchStart)..<(max(e, s + 1) - t.searchStart), quiet: true)
        } else {
            pendingLbn = lbn.isEmpty ? nil : lbn
            openReader(text: ti, juan: juan, focus: nil)
        }
    }

    // MARK: remembering the place between launches

    func saveLastPlace() {
        guard let ix = index, let p = currentPlace() else { return }
        // prefer the first line on screen: that is what the reader shows when it comes back
        var lbn = p.lbn
        if let r = rendered, let probe = topProbe, let top = r.lbn(at: probe()) { lbn = top }
        let d = UserDefaults.standard
        d.set(ix.texts[p.ti].id, forKey: "last.text")
        d.set(p.juan, forKey: "last.juan")
        d.set(lbn, forKey: "last.lbn")
    }

    func restoreLastPlace() {
        guard let ix = index, readerText == nil else { return }
        let d = UserDefaults.standard
        guard let id = d.string(forKey: "last.text"), let ti = ix.textIndexById[id] else { return }
        openPlace(text: ti, juan: d.integer(forKey: "last.juan"), lbn: d.string(forKey: "last.lbn") ?? "", highlight: false)
    }
}
