import SwiftUI
import UniformTypeIdentifiers

/// Lays chips out in rows, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    private func rows(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return (frames, y + rowH)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600
        return CGSize(width: w, height: rows(subviews, width: w).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = rows(subviews, width: bounds.width)
        for (v, f) in zip(subviews, r.frames) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
}

/// Spaces and line breaks made visible, for the chips of fixed text.
private func visible(_ s: String) -> String {
    s.replacingOccurrences(of: " ", with: "␣").replacingOccurrences(of: "\n", with: "↵")
}

private struct PieceDrop: DropDelegate {
    let target: UUID?
    let settings: CitationSettings
    func dropEntered(info: DropInfo) { withAnimation(.easeInOut(duration: 0.12)) { settings.dragEntered(target) } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { settings.dragging = nil; settings.draggingNew = nil; return true }
}

/// Dropping a piece back on the shelf of elements takes it out of the format.
private struct ShelfDrop: DropDelegate {
    let settings: CitationSettings
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        settings.remove(settings.dragging)
        settings.dragging = nil; settings.draggingNew = nil
        return true
    }
}

struct CitationSettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var settings: CitationSettings

    var body: some View {
        let sample = state.selectedCitationSource() ?? .sample
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Citation Format").font(.title3).bold()
                Spacer()
                Menu(settings.name.isEmpty ? "Formats" : settings.name) {
                    if !settings.saved.isEmpty {
                        Section("Your saved formats") {
                            ForEach(settings.saved) { s in Button(s.name) { settings.use(s.format, named: s.name) } }
                        }
                        Menu("Delete a saved format") {
                            ForEach(settings.saved) { s in Button(s.name) { settings.delete(s.name) } }
                        }
                    }
                    Section("Start from an example") {
                        ForEach(CiteFormat.presets.indices, id: \.self) { i in
                            Button(CiteFormat.presets[i].name) {
                                var f = CiteFormat.presets[i].make()
                                f.excluded = settings.format.excluded
                                settings.use(f, named: "")
                            }
                        }
                    }
                }
                .fixedSize()
                .help("Switch to a format you saved, or start a new one from an example")
            }
            Text("Copy with Citation (⇧⌘C) copies the selected passage as the printed edition has it, followed by its place and the variant readings. Drag the pieces to reorder them, drag new ones in from the shelf below, and click a piece to change how it is written.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            // the format itself
            FlowLayout {
                ForEach(settings.format.pieces) { p in
                    chip(p)
                        .onTapGesture { settings.selected = settings.selected == p.id ? nil : p.id }
                        .onDrag {
                            settings.dragging = p.id; settings.draggingNew = nil
                            return NSItemProvider(object: p.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: PieceDrop(target: p.id, settings: settings))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.3)))
            .onDrop(of: [UTType.text], delegate: PieceDrop(target: nil, settings: settings))

            inspector

            // the shelf
            VStack(alignment: .leading, spacing: 5) {
                Text("Elements — drag into the format, or double-click to add at the end. Drop a piece here to remove it.")
                    .font(.caption).foregroundColor(.secondary)
                FlowLayout {
                    ForEach(CiteKind.allCases.filter { $0 != .sectionNumber }, id: \.self) { k in
                        Text(k.name)
                            .font(.callout)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .contentShape(Capsule())
                            .onTapGesture(count: 2) { _ = settings.add(k) }
                            .onDrag {
                                settings.dragging = nil; settings.draggingNew = k
                                return NSItemProvider(object: k.rawValue as NSString)
                            }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.07)))
            .onDrop(of: [UTType.text], delegate: ShelfDrop(settings: settings))

            HStack(spacing: 8) {
                Text("Between the start and end of a passage")
                TextField("", text: $settings.format.dash).frame(width: 44).multilineTextAlignment(.center)
                Text("(a29–b1)").foregroundColor(.secondary)
            }
            .font(.callout)

            editions

            VStack(alignment: .leading, spacing: 4) {
                Text(state.selectedCitationSource() == nil ? "Preview (an example)" : "Preview (your selection)").font(.caption).foregroundColor(.secondary)
                ScrollView {
                    Text(String(settings.format.render(sample).prefix(1500)))
                        .font(rareCharacterFont).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))

            HStack {
                TextField("Name for this format", text: $settings.name).frame(width: 220)
                    .onSubmit { settings.saveAs() }
                Button(settings.saved.contains { $0.name == settings.name.trimmingCharacters(in: .whitespaces) } ? "Update Saved Format" : "Save Format") { settings.saveAs() }
                    .disabled(settings.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Keep this format under the name on the left, to switch back to it later")
                Spacer()
                Button("Done") { state.showCitationSettings = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    private func chip(_ p: CitePiece) -> some View {
        let on = settings.selected == p.id
        return HStack(spacing: 2) {
            if p.kind == .literal {
                Text(p.text.isEmpty ? "…" : visible(p.text)).font(.system(.callout, design: .monospaced))
            } else {
                if !p.before.isEmpty { Text(visible(p.before)).foregroundColor(.secondary) }
                Text(p.kind.name).bold()
                if !p.after.isEmpty { Text(visible(p.after)).foregroundColor(.secondary) }
            }
        }
        .font(.callout)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(p.kind == .literal ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.18)))
        .overlay(Capsule().stroke(on ? Color.accentColor : Color.clear, lineWidth: 2))
        .contentShape(Capsule())
    }

    /// How the clicked piece is written.
    @ViewBuilder private var inspector: some View {
        if let i = settings.index(of: settings.selected) {
            let p = settings.format.pieces[i]
            HStack(spacing: 8) {
                Text(p.kind.name).bold()
                if p.kind == .literal {
                    TextField("text", text: $settings.format.pieces[i].text).frame(width: 150)
                } else {
                    Text("before")
                    TextField("", text: $settings.format.pieces[i].before).frame(width: 70)
                    Text("after")
                    TextField("", text: $settings.format.pieces[i].after).frame(width: 70)
                    if !p.kind.styles.isEmpty {
                        let labels = p.kind.customLabels
                        Picker("written as", selection: Binding(get: { min(p.style, p.kind.styles.count) }, set: { v in
                            settings.format.pieces[i].style = v
                            if v == p.kind.styles.count, p.custom?.count != labels.count { settings.format.pieces[i].custom = p.kind.customDefaults }
                        })) {
                            ForEach(p.kind.styles.indices, id: \.self) { k in Text(p.kind.styles[k]).tag(k) }
                            if !labels.isEmpty { Text("My own wording…").tag(p.kind.styles.count) }
                        }
                        .fixedSize()
                        // the user's own wording for the element
                        if p.style >= p.kind.styles.count, let c = p.custom, c.count == labels.count {
                            ForEach(labels.indices, id: \.self) { k in
                                TextField(labels[k], text: Binding(get: { settings.format.pieces[i].custom?[k] ?? "" },
                                                                   set: { settings.format.pieces[i].custom?[k] = $0 }))
                                    .frame(width: labels.count == 1 ? 150 : 74)
                                    .help("Written for " + labels[k])
                            }
                        }
                    }
                }
                Spacer()
                Button { settings.move(p.id, by: -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(i == 0).help("Move this piece one place earlier")
                Button { settings.move(p.id, by: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(i == settings.format.pieces.count - 1).help("Move this piece one place later")
                Button("Remove") { settings.remove(p.id) }
            }
            .font(.callout)
        } else {
            Text("Click a piece to set the characters before and after it and the language it is written in.")
                .font(.callout).foregroundColor(.secondary)
        }
    }

    /// Which editions the variant notes report.
    @ViewBuilder private var editions: some View {
        let here = state.rendered?.doc?.witnessLabels ?? []
        let all = here + settings.format.excluded.filter { !here.contains($0) }
        VStack(alignment: .leading, spacing: 5) {
            Text(all.isEmpty ? "Editions in the variant notes: open a text to choose among its editions."
                             : "Editions in the variant notes (those of the text being read; 【CB】 is CBETA's correction)")
                .font(.caption).foregroundColor(.secondary)
            FlowLayout(spacing: 10) {
                ForEach(all, id: \.self) { w in
                    Toggle(w, isOn: Binding(get: { !settings.format.excluded.contains(w) }, set: { settings.setExcluded(w, !$0) }))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }
}
