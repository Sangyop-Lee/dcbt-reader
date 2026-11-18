import SwiftUI
import AppKit

/// Widths of the columns and height of the pane under the text, as shares of
/// the window, remembered between launches.
final class PaneLayout: ObservableObject {
    static let defaultSidebar: CGFloat = 0.20
    static let defaultResults: CGFloat = 0.20
    static let defaultBottom: CGFloat = 0.25

    @Published var sidebar: CGFloat
    @Published var results: CGFloat
    @Published var bottom: CGFloat
    var dragStart: CGFloat? = nil

    init() {
        let d = UserDefaults.standard
        func read(_ key: String, _ fallback: CGFloat) -> CGFloat {
            let v = d.double(forKey: key)
            return v > 0.03 && v < 0.9 ? CGFloat(v) : fallback
        }
        sidebar = read("layout.sidebar", PaneLayout.defaultSidebar)
        results = read("layout.results", PaneLayout.defaultResults)
        bottom = read("layout.bottom", PaneLayout.defaultBottom)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(Double(sidebar), forKey: "layout.sidebar")
        d.set(Double(results), forKey: "layout.results")
        d.set(Double(bottom), forKey: "layout.bottom")
    }

    func reset() {
        sidebar = PaneLayout.defaultSidebar
        results = PaneLayout.defaultResults
        bottom = PaneLayout.defaultBottom
        save()
    }
}

func clampSize(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(v, max(lo, hi))) }

/// The line between two panes; drag it to resize them.
struct SplitHandle: View {
    @ObservedObject var layout: PaneLayout
    let columns: Bool                           // true: between columns (drag sideways)
    let current: () -> CGFloat                  // the share being changed
    let change: (_ start: CGFloat, _ moved: CGFloat) -> Void

    var body: some View {
        ZStack {
            Color.clear
            Rectangle().fill(Color(NSColor.separatorColor)).frame(width: columns ? 1 : nil, height: columns ? nil : 1)
        }
        .frame(width: columns ? 7 : nil, height: columns ? nil : 7)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { (columns ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                if layout.dragStart == nil { layout.dragStart = current() }
                change(layout.dragStart!, columns ? v.translation.width : v.translation.height)
            }
            .onEnded { _ in
                layout.dragStart = nil
                layout.save()
            })
    }
}
