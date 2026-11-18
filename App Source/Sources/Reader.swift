import AppKit
import SwiftUI

// MARK: - Rendering one juan

struct AppRow: Identifiable {
    var id: Int
    var lbn: String
    var entry: AppEntry
    var range: NSRange          // where the lemma (or its replacement) sits in the rendered text

    /// CBETA-style apparatus line, e.g. "辨＝辯【宋】".
    var summary: String {
        var parts: [String] = []
        for r in entry.rdgs {
            let w = r.wits.joined()
            if entry.lem.isEmpty { parts.append("＋\(r.text)\(w)") }
            else if r.text.isEmpty { parts.append("〔\(entry.lem)〕－\(w)") }
            else { parts.append("\(entry.lem)＝\(r.text)\(w)") }
        }
        return parts.joined(separator: "，")
    }
}

final class RenderedJuan {
    var attr = NSAttributedString()
    var apps: [AppRow] = []
    var lineStarts: [(loc: Int, lbn: String)] = []
    var juanSearchStart = 0     // file-relative
    var searchMap: [Int32] = [] // per search unit of the juan -> utf16 location in attr (-1 = not shown)
    var focus: NSRange? = nil
    var doc: ParsedDoc? = nil
    /// Where each piece of the text itself sits: (location, length, token). Line numbers and an edition's
    /// substituted readings are not in it. `whole` marks an image standing for the whole token.
    var runs: [(loc: Int, len: Int, tok: Int, whole: Bool)] = []

    func location(ofSearchRange r: Range<Int>) -> NSRange? {
        var first = -1, last = -1
        var i = max(r.lowerBound - juanSearchStart, 0)
        let end = min(r.upperBound - juanSearchStart, searchMap.count)
        while i < end {
            let l = Int(searchMap[i])
            if l >= 0 { if first < 0 { first = l }; last = l }
            i += 1
        }
        if first < 0 { return nil }
        return NSRange(location: first, length: last - first + 1)
    }

    func lbn(at loc: Int) -> String? {
        var lo = 0, hi = lineStarts.count - 1
        if hi < 0 { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid].loc <= loc { lo = mid } else { hi = mid - 1 }
        }
        return lineStarts[lo].lbn
    }
}

/// Token ranges of each juan, using the same rule as the indexer.
func juanSegments(_ doc: ParsedDoc) -> [(tok: Int, searchStart: Int, dispStart: Int)] {
    var segs: [(Int, Int, Int)] = []
    var count = 0
    var disp = 0        // UTF-16 length of all text so far: the same count the index keeps as display offsets
    for (i, t) in doc.toks.enumerated() {
        switch t {
        case .juan: segs.append((i, count, disp))
        case .text(let s, let st):
            if !st.contains(.displayOnly) { count += countSearchUnits(s) }
            disp += s.utf16.count
        default: break
        }
    }
    if segs.isEmpty || segs[0].1 > 0 { segs.insert((0, 0, 0), at: 0) }
    return segs
}

/// Marks the page-column-line label at the start of a line in original-line mode.
let lineLabelKey = NSAttributedString.Key("dcbLineLabel")

struct RenderOptions {
    var edition: String? = nil      // witness label, nil = CBETA's corrected base text
    var lineMode = false            // line numbers inside the running text
    var lineBreaks = false          // one printed line per row, with its number in front
    var fontSize: CGFloat = 18
}

func renderJuan(doc: ParsedDoc, juan: Int, options: RenderOptions,
                marks: [Range<Int>], focus: Range<Int>?, focusParts: [Range<Int>] = [],
                dispFocus: Range<Int>? = nil, quietFocus: Bool = false,
                shared: [UInt8]? = nil, sharedMin: Int = 3) -> RenderedJuan {
    let out = RenderedJuan()
    out.doc = doc
    let segs = juanSegments(doc)
    let j = min(max(juan, 0), segs.count - 1)
    let tokStart = segs[j].tok
    let tokEnd = j + 1 < segs.count ? segs[j + 1].tok : doc.toks.count
    out.juanSearchStart = segs[j].searchStart

    var byFrom: [String: [Int]] = [:]
    var byTo: [String: [Int]] = [:]
    for (i, a) in doc.apps.enumerated() {
        byFrom[a.from, default: []].append(i)
        byTo[a.to, default: []].append(i)
    }

    let size = options.fontSize
    let gaiji = GaijiStore.shared
    let baseFont = gaiji.font("Songti TC", size: size)
    let headFont = gaiji.font("Songti TC Bold", size: size + 2)
    let noteFont = gaiji.font("Songti TC", size: size * 0.82)
    let refFont = NSFont.monospacedDigitSystemFont(ofSize: max(size * 0.6, 10), weight: .regular)
    let para = NSMutableParagraphStyle()
    para.lineSpacing = size * 0.45
    para.paragraphSpacing = options.lineBreaks ? 0 : size * 0.6
    let base: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
    let s = NSMutableAttributedString()
    var open: [Int: (start: Int, row: Int)] = [:]
    var suppressUntil: String? = nil
    var curLbn = ""
    var map: [Int32] = []
    // an exact passage to highlight, given as display offsets (punctuation included)
    var dispOff = segs[j].dispStart
    var dfFirst = -1, dfEnd = -1
    func noteDisp(_ lo: Int, _ hi: Int) { if dfFirst < 0 { dfFirst = lo }; dfEnd = max(dfEnd, hi) }

    /// Applies attributes to the text of a range only: line breaks and line-number
    /// labels inside it are skipped, so a highlight never runs to the margin.
    func paint(_ attrs: [NSAttributedString.Key: Any], _ r: NSRange) {
        let str = s.mutableString
        var runStart = -1
        let end = min(r.location + r.length, s.length)
        var i = r.location
        while i <= end {
            let skip = i == end || str.character(at: i) == 10 || s.attribute(lineLabelKey, at: i, effectiveRange: nil) != nil
            if skip {
                if runStart >= 0 { s.addAttributes(attrs, range: NSRange(location: runStart, length: i - runStart)); runStart = -1 }
            } else if runStart < 0 { runStart = i }
            i += 1
        }
    }

    func endsWithNewline() -> Bool { s.length == 0 || s.mutableString.character(at: s.length - 1) == 10 }

    // the page-column-line number, small and grey
    var labelAttrs = base
    labelAttrs[.font] = refFont
    labelAttrs[.foregroundColor] = NSColor.tertiaryLabelColor
    labelAttrs[lineLabelKey] = true
    var pendingLbn: String? = nil
    func flushLabel() {
        guard let n = pendingLbn else { return }
        pendingLbn = nil
        out.lineStarts.append((s.length, n))
        s.append(NSAttributedString(string: (endsWithNewline() ? "" : "\u{2009}") + prettyLbn(n) + "\u{2009}", attributes: labelAttrs))
    }

    for ti in tokStart..<tokEnd {
        switch doc.toks[ti] {
        case .juan, .section:
            break
        case .lb(let n):
            curLbn = n
            flushLabel()
            // line by line: each printed line starts a new row
            if options.lineBreaks && !endsWithNewline() { s.append(NSAttributedString(string: "\n", attributes: base)) }
            if options.lineMode && !options.lineBreaks {
                // inside the running text the number waits for the line's first words, so that a
                // verse or heading that starts here takes it along instead of leaving it on a row of its own
                pendingLbn = n
            } else {
                out.lineStarts.append((s.length, n))
                if options.lineBreaks { s.append(NSAttributedString(string: prettyLbn(n) + "  ", attributes: labelAttrs)) }
            }
        case .para:
            if !options.lineBreaks && !endsWithNewline() { s.append(NSAttributedString(string: "\n", attributes: base)) }
        case .anchor(let id):
            if let idxs = byFrom[id] {
                for ai in idxs {
                    let entry = doc.apps[ai]
                    let start = s.length
                    if let ed = options.edition, suppressUntil == nil,
                       let r = entry.rdgs.first(where: { $0.wits.contains(ed) }) {
                        flushLabel()
                        var a = base
                        a[.foregroundColor] = NSColor.systemRed
                        s.append(NSAttributedString(string: r.text.isEmpty ? "\u{2205}" : r.text, attributes: a))
                        if entry.to != entry.from { suppressUntil = entry.to }
                    }
                    out.apps.append(AppRow(id: out.apps.count, lbn: curLbn, entry: entry,
                                           range: NSRange(location: start, length: s.length - start)))
                    open[ai] = (start, out.apps.count - 1)
                }
            }
            if let idxs = byTo[id] {
                for ai in idxs {
                    guard let o = open[ai] else { continue }
                    open[ai] = nil
                    var r = NSRange(location: o.start, length: s.length - o.start)
                    if r.length == 0 {
                        // nothing in the base text here (other editions add words): leave a clickable mark
                        flushLabel()
                        var a = base
                        a[.foregroundColor] = NSColor.systemBlue
                        a[.font] = noteFont
                        s.append(NSAttributedString(string: "\u{2038}", attributes: a))
                        r.length = 1
                    }
                    out.apps[o.row].range = r
                    s.addAttribute(.link, value: "app:\(o.row)", range: r)
                    // variant readings: a solid, thick underline on a faint tint
                    paint([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: NSColor.systemBlue,
                           .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.13)], r)
                }
            }
            if suppressUntil == id { suppressUntil = nil }
        case .text(let str, let st):
            let searchable = !st.contains(.displayOnly)
            let dispLen = str.utf16.count
            let tokDisp = dispOff
            dispOff += dispLen
            if suppressUntil != nil {
                if searchable { for _ in 0..<countSearchUnits(str) { map.append(-1) } }
                continue
            }
            flushLabel()
            var a = base
            if st.contains(.head) { a[.font] = headFont }
            if st.contains(.byline) { a[.foregroundColor] = NSColor.secondaryLabelColor }
            if st.contains(.note) { a[.font] = noteFont; a[.foregroundColor] = NSColor.systemBrown }
            let start = s.length
            if st.contains(.gaiji), let g = doc.gaiji[ti], let f = a[.font] as? NSFont,
               let img = gaiji.image(g.id, height: (f.pointSize * 1.02).rounded(),
                                     color: (a[.foregroundColor] as? NSColor) ?? .labelColor) {
                // a character outside Unicode: CBETA's image of it, standing in for the stand-in text
                let att = NSTextAttachment()
                att.image = img
                att.bounds = CGRect(x: 0, y: f.descender * 0.75, width: img.size.width, height: img.size.height)
                let piece = NSMutableAttributedString(attachment: att)
                a[.toolTip] = g.note
                piece.addAttributes(a, range: NSRange(location: 0, length: piece.length))
                s.append(piece)
                out.runs.append((start, piece.length, ti, true))
                if searchable { for _ in 0..<countSearchUnits(str) { map.append(Int32(start)) } }
                if let f = dispFocus, f.lowerBound < tokDisp + dispLen, f.upperBound > tokDisp { noteDisp(start, start + 1) }
                continue
            }
            s.append(NSAttributedString(string: str, attributes: a))
            out.runs.append((start, dispLen, ti, false))
            if let f = dispFocus, f.lowerBound < tokDisp + dispLen, f.upperBound > tokDisp {
                noteDisp(start + max(f.lowerBound - tokDisp, 0), start + min(f.upperBound - tokDisp, dispLen))
            }
            if searchable {
                var off = start
                for u in str.unicodeScalars {
                    let w = u.value < 0x10000 ? 1 : 2
                    if isSearchScalar(u.value) { for _ in 0..<w { map.append(Int32(off)) } }
                    off += w
                }
            }
        }
    }
    flushLabel()
    out.searchMap = map

    // passages shared with the text compared with: the longer the shared run, the stronger the tint
    if let sh = shared {
        let first = out.juanSearchStart
        var k = 0
        while k < map.count, first + k < sh.count {
            let level = Int(sh[first + k])
            if level < sharedMin || map[k] < 0 { k += 1; continue }
            var e = k
            while e + 1 < map.count, first + e + 1 < sh.count, Int(sh[first + e + 1]) == level, map[e + 1] >= 0 { e += 1 }
            let lo = Int(map[k])
            var hi = Int(map[e]) + 1
            if hi < s.length, UTF16.isLeadSurrogate(s.mutableString.character(at: hi - 1)) { hi += 1 }
            if hi > lo {
                paint([.backgroundColor: NSColor.systemTeal.withAlphaComponent(0.10 + 0.08 * CGFloat(min(level, 8) - 3))],
                      NSRange(location: lo, length: hi - lo))
            }
            k = e + 1
        }
    }

    let markColor = NSColor.systemYellow.withAlphaComponent(0.4)
    let quiet = NSColor.systemOrange.withAlphaComponent(0.19)     // a place gone to by citation or bookmark
    for m in marks {
        if let r = out.location(ofSearchRange: m) { paint([.backgroundColor: markColor], r) }
    }
    if let f = focus, let r = out.location(ofSearchRange: f) {
        let strong = NSColor.systemOrange.withAlphaComponent(0.55)
        if focusParts.isEmpty {
            // a search hit stands out; a cited line, column or page only gets a wash
            paint([.backgroundColor: quietFocus ? quiet : strong], r)
        } else {
            // several terms: tint the passage lightly and each term strongly
            paint([.backgroundColor: NSColor.systemOrange.withAlphaComponent(0.16)], r)
            for p in focusParts {
                if let pr = out.location(ofSearchRange: p) { paint([.backgroundColor: strong], pr) }
            }
        }
        out.focus = r
    }
    if dfFirst >= 0 && dfEnd > dfFirst {
        let r = NSRange(location: dfFirst, length: dfEnd - dfFirst)
        paint([.backgroundColor: NSColor.systemOrange.withAlphaComponent(0.45)], r)
        out.focus = r
    }
    out.attr = s
    return out
}

// MARK: - Text view

/// The box drawn round a shared passage while the pointer is on it; one rectangle per line it runs over.
final class PassageOutline: NSView {
    var rects: [NSRect] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemTeal.setStroke()
        for r in rects {
            let path = NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: 0.5), xRadius: 3, yRadius: 3)
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}

struct ReaderTextView: NSViewRepresentable {
    var background: NSColor
    var rendered: RenderedJuan?
    var version: Int
    var scrollTo: NSRange?
    var scrollVersion: Int
    var alignTop: Bool
    var registerTopProbe: (@escaping () -> Int) -> Void
    var onApp: (Int) -> Void
    var onLocation: (Int) -> Void
    var onScroll: (Int) -> Void = { _ in }
    var onSelection: (String) -> Void = { _ in }
    var onRange: (NSRange) -> Void = { _ in }
    var onCopyCitation: () -> Void = {}
    var onHover: (Int) -> NSRange? = { _ in nil }       // the passage to outline for the character under the pointer
    var onPassageClick: (Int) -> Void = { _ in }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReaderTextView
        var version = -1
        var scrollVersion = -1
        weak var textView: NSTextView?
        weak var scroll: NSScrollView?
        private var lastScrollReport = Date.distantPast
        private var scrollReportPending = false
        private let outline = PassageOutline()
        private var outlined = NSRange(location: NSNotFound, length: 0)
        private var clickMonitor: Any?
        init(_ p: ReaderTextView) { parent = p }
        deinit {
            NotificationCenter.default.removeObserver(self)
            if let m = clickMonitor { NSEvent.removeMonitor(m) }
        }

        /// The character under the pointer, if the pointer is on one.
        private func character(at e: NSEvent) -> Int? {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, e.window === tv.window,
                  (tv.textStorage?.length ?? 0) > 0 else { return nil }
            let p = tv.convert(e.locationInWindow, from: nil)
            guard tv.visibleRect.contains(p) else { return nil }
            let pt = NSPoint(x: p.x - tv.textContainerOrigin.x, y: p.y - tv.textContainerOrigin.y)
            let g = lm.glyphIndex(for: pt, in: tc)
            guard lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).contains(pt) else { return nil }
            return lm.characterIndexForGlyph(at: g)
        }

        /// Draws a box round the shared passage under the pointer, or removes it.
        func outlinePassage(_ r: NSRange?) {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            guard let r = r, r.length > 0, r.location + r.length <= (tv.textStorage?.length ?? 0) else {
                outlined = NSRange(location: NSNotFound, length: 0)
                outline.removeFromSuperview()
                return
            }
            if NSEqualRanges(r, outlined), outline.superview != nil { return }
            outlined = r
            var rects: [NSRect] = []
            let o = tv.textContainerOrigin
            lm.enumerateEnclosingRects(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil),
                                       withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { rect, _ in
                rects.append(rect.offsetBy(dx: o.x, dy: o.y))
            }
            guard let first = rects.first else { return }
            let frame = rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -3, dy: -3)
            outline.rects = rects.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
            outline.frame = frame
            if outline.superview !== tv { tv.addSubview(outline) }
            outline.needsDisplay = true
        }

        // named as AppKit calls them on the owner of a tracking area
        @objc(mouseMoved:) func mouseMoved(with e: NSEvent) { outlinePassage(character(at: e).flatMap { parent.onHover($0) }) }
        @objc(mouseExited:) func mouseExited(with e: NSEvent) { outlinePassage(nil) }
        @objc(mouseEntered:) func mouseEntered(with e: NSEvent) {}

        /// A plain click on a shared passage (not a drag, not on a variant) is passed on.
        func watchClicks() {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
                if let self = self, let tv = self.textView, e.clickCount == 1, tv.selectedRange().length == 0,
                   let c = self.character(at: e), tv.textStorage?.attribute(.link, at: c, effectiveRange: nil) == nil,
                   self.parent.onHover(c) != nil {
                    DispatchQueue.main.async { self.parent.onPassageClick(c) }
                }
                return e
            }
        }

        /// The text was scrolled: report the character a third of the way down
        /// the visible area (where a revealed passage is placed), at most ~12 times a second.
        @objc func boundsChanged(_ note: Notification) {
            let wait = 0.08 - Date().timeIntervalSince(lastScrollReport)
            if wait <= 0 { reportScroll(); return }
            if scrollReportPending { return }
            scrollReportPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.scrollReportPending = false
                self?.reportScroll()
            }
        }

        private func reportScroll() {
            guard let tv = textView, let scroll = scroll, let lm = tv.layoutManager, let tc = tv.textContainer,
                  (tv.textStorage?.length ?? 0) > 0 else { return }
            lastScrollReport = Date()
            let b = scroll.contentView.bounds
            let pt = NSPoint(x: b.width / 2, y: max(b.minY + b.height / 3 - tv.textContainerOrigin.y, 0))
            parent.onScroll(lm.characterIndexForGlyph(at: lm.glyphIndex(for: pt, in: tc)))
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let s = link as? String, s.hasPrefix("app:"), let n = Int(s.dropFirst(4)) { parent.onApp(n) }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            let r = tv.selectedRange()
            parent.onLocation(r.location)
            parent.onRange(r)
            if r.length > 0, r.length <= 6000 { parent.onSelection((tv.string as NSString).substring(with: r)) }
            else { parent.onSelection("") }
        }

        /// The right-click menu of a selection offers the copy that carries its citation.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard view.selectedRange().length > 0 else { return menu }
            let item = NSMenuItem(title: "Copy with Citation", action: #selector(copyCitation), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        @objc func copyCitation() { parent.onCopyCitation() }

        /// Character index at the top-left of what is currently visible.
        func topVisibleCharacter() -> Int {
            guard let tv = textView, let scroll = scroll, let lm = tv.layoutManager, let tc = tv.textContainer,
                  (tv.textStorage?.length ?? 0) > 0 else { return 0 }
            let o = tv.textContainerOrigin
            let pt = NSPoint(x: 4, y: max(scroll.contentView.bounds.minY - o.y + 4, 0))
            return lm.characterIndexForGlyph(at: lm.glyphIndex(for: pt, in: tc))
        }

        func reveal(_ r: NSRange, flash: Bool, top: Bool = false) {
            guard let tv = textView, let scroll = scroll, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let len = tv.textStorage?.length ?? 0
            guard r.location >= 0, r.location + r.length <= len else { return }
            lm.ensureLayout(for: tc)
            let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: g, in: tc)
            rect.origin.y += tv.textContainerOrigin.y
            let visible = scroll.contentView.bounds.height
            let maxY = max((scroll.documentView?.frame.height ?? 0) - visible, 0)
            let y = min(max(top ? rect.minY - 6 : rect.midY - visible / 3, 0), maxY)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            if top { parent.onLocation(r.location) } else { tv.setSelectedRange(NSRange(location: r.location, length: 0)) }
            if flash && r.length > 0 { tv.showFindIndicator(for: r) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 22, height: 18)
        tv.backgroundColor = background
        scroll.backgroundColor = background
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        // lay out only what is on screen: a long juan no longer has to be set in full before it can scroll
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        context.coordinator.scroll = scroll
        let c = context.coordinator
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        registerTopProbe { [weak c] in c?.topVisibleCharacter() ?? 0 }
        tv.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                          owner: c, userInfo: nil))
        c.watchClicks()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        if tv.backgroundColor != background { tv.backgroundColor = background; scroll.backgroundColor = background }
        if c.version != version {
            c.version = version
            c.outlinePassage(nil)
            tv.textStorage?.setAttributedString(rendered?.attr ?? NSAttributedString())
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            if scrollTo == nil || c.scrollVersion == scrollVersion {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if c.scrollVersion != scrollVersion {
            c.scrollVersion = scrollVersion
            if let r = scrollTo {
                let top = alignTop
                DispatchQueue.main.async { c.reveal(r, flash: !top, top: top) }
            }
        }
    }
}
