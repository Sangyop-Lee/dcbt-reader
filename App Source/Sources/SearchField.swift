import SwiftUI
import AppKit

/// The search box. Putting the cursor in it selects everything already there,
/// so typing or pasting replaces the previous query.
struct SearchField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void
    var onRecent: (Bool) -> Void = { _ in }     // show or hide the list of past searches

    final class Field: NSTextField {
        /// True until the box has been clicked once since the last search or the
        /// last click elsewhere: that first click selects everything; a second
        /// click then places the caret as usual.
        var pristine = true
        var onRecent: (Bool) -> Void = { _ in }
        private var hideOnMouseUp = false
        private var monitor: Any?

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            // reached by keyboard (Tab): select everything. Clicks are handled below.
            if ok, NSApp.currentEvent?.type != .leftMouseDown {
                DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
            }
            return ok
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            // The first click in the box is taken over entirely: the box gets the
            // cursor with everything selected, in one step. Passing the click on
            // to the text editor as well would first place a caret and make the
            // selection flicker.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
                guard let self = self, e.window === self.window else { return e }
                if e.type == .leftMouseUp {
                    // a click elsewhere closes the list of past searches, once the click has done its work there
                    if self.hideOnMouseUp { self.hideOnMouseUp = false; DispatchQueue.main.async { self.onRecent(false) } }
                    return e
                }
                let inside = self.bounds.contains(self.convert(e.locationInWindow, from: nil))
                guard inside else { self.pristine = true; self.hideOnMouseUp = true; return e }
                self.onRecent(true)
                guard self.pristine, e.clickCount == 1 else { return e }
                self.pristine = false
                if self.currentEditor() == nil { self.window?.makeFirstResponder(self) }
                self.currentEditor()?.selectAll(nil)
                return nil
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ p: SearchField) { parent = p }
        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            if parent.text != f.stringValue { parent.text = f.stringValue }
            parent.onRecent(false)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = control.stringValue
                parent.onSubmit()
                textView.selectAll(nil)      // ready for the next query
                (control as? Field)?.pristine = true
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.onRecent(false) }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let f = Field()
        f.delegate = context.coordinator
        f.font = NSFont.systemFont(ofSize: 15)
        f.bezelStyle = .roundedBezel
        f.isBordered = true
        f.isBezeled = true
        f.lineBreakMode = .byTruncatingTail
        f.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.placeholderString = placeholder
        f.stringValue = text
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateNSView(_ f: Field, context: Context) {
        context.coordinator.parent = self
        f.onRecent = onRecent
        if f.placeholderString != placeholder { f.placeholderString = placeholder }
        // never disturb a Chinese input method while it is composing
        if let ed = f.currentEditor() as? NSTextView, ed.hasMarkedText() { return }
        if f.stringValue != text { f.stringValue = text }
    }
}
