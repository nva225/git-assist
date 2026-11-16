import AppKit
import SwiftUI

enum FieldCommand {
    case tab, backtab, up, down, enter, escape
}

/// The search box: an NSTextField so Tab, arrows, Return, and Esc can drive autocomplete
/// and the result list instead of moving focus.
struct QueryField: NSViewRepresentable {
    @ObservedObject var model: MainViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = "Search PRs — try author:, commenter:me, comment:, is:approved"
        field.delegate = context.coordinator
        field.cell?.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        model.field = field
        context.coordinator.observeSelection(of: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        guard context.coordinator.appliedVersion != model.editVersion else { return }
        context.coordinator.appliedVersion = model.editVersion
        field.stringValue = model.query
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: model.cursor, length: 0)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: MainViewModel
        var appliedVersion = 0
        private var selectionObserver: NSObjectProtocol?

        init(model: MainViewModel) { self.model = model }

        deinit {
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        }

        func observeSelection(of field: NSTextField) {
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main
            ) { [weak self, weak field] note in
                guard let field, let editor = field.currentEditor(), note.object as AnyObject === editor else { return }
                MainActor.assumeIsolated { self?.model.cursorMoved(to: editor.selectedRange.location) }
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let cursor = field.currentEditor()?.selectedRange.location ?? field.stringValue.count
            MainActor.assumeIsolated { model.textChanged(field.stringValue, cursor: cursor) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let command: FieldCommand
            switch selector {
            case #selector(NSResponder.insertTab(_:)): command = .tab
            case #selector(NSResponder.insertBacktab(_:)): command = .backtab
            case #selector(NSResponder.moveUp(_:)): command = .up
            case #selector(NSResponder.moveDown(_:)): command = .down
            case #selector(NSResponder.insertNewline(_:)): command = .enter
            case #selector(NSResponder.cancelOperation(_:)): command = .escape
            default: return false
            }
            return MainActor.assumeIsolated { model.handle(command) }
        }
    }
}
