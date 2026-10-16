import AppKit
import SwiftUI

/// Paste must use the inserted text: the resulting field string cannot identify the old digit.
final class ArrivalClockFieldEditor: NSTextView {
    var readPasteboard: () -> String? = { NSPasteboard.general.string(forType: .string) }
    var onPaste: (String) -> Void = { _ in }

    override func paste(_ sender: Any?) {
        if let text = readPasteboard() { onPaste(text) }
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
}

final class ArrivalClockDigitCell: NSTextFieldCell {
    let editor = ArrivalClockFieldEditor()
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor.isFieldEditor = true
        return editor
    }
}

struct ArrivalClockDigitField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusedDigit: Int?
    let index: Int
    let color: NSColor
    let label: String
    let onPaste: (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        let cell = ArrivalClockDigitCell(textCell: "")
        field.cell = cell
        field.delegate = context.coordinator
        field.isEditable = true; field.isSelectable = true
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none; field.alignment = .center
        field.placeholderString = "0"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 31, weight: .semibold)
        field.font = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 31) } ?? font
        cell.usesSingleLineMode = true
        cell.editor.onPaste = { [weak field, weak coordinator = context.coordinator] input in
            guard let field, let coordinator else { return }
            coordinator.parent.onPaste(input)
            coordinator.synchronize(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronize(field)
        field.textColor = color
        field.setAccessibilityLabel(label)
        if focusedDigit == index, field.currentEditor() == nil {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                guard let field, let coordinator, coordinator.parent.focusedDigit == coordinator.parent.index,
                      field.currentEditor() == nil else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ArrivalClockDigitField
        init(_ parent: ArrivalClockDigitField) { self.parent = parent }

        func synchronize(_ field: NSTextField) {
            if field.stringValue != parent.text { field.stringValue = parent.text }
            if let editor = field.currentEditor(), editor.string != parent.text {
                editor.string = parent.text
                editor.selectedRange = NSRange(location: parent.text.utf16.count, length: 0)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            synchronize(field)
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focusedDigit = parent.index }
        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.focusedDigit == parent.index { parent.focusedDigit = nil }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            if command == #selector(NSResponder.cancelOperation(_:)) { parent.onCancel(); return true }
            return false
        }
    }
}
