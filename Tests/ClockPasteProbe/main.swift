import AppKit
import SwiftUI
import AfterSixCore

@MainActor
private final class Draft {
    var edit: ArrivalClockEdit
    var focus: Int?
    var submits = 0
    var cancels = 0
    init() {
        let now = ISO8601DateFormatter().date(from: "2026-10-16T02:11:00Z")!
        edit = ArrivalClockEdit(existingTime: now, now: now, timeZone: TimeZone(identifier: "Asia/Seoul")!)
    }
}

@MainActor
private func textField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField { return field }
    return view.subviews.lazy.compactMap { textField(in: $0) }.first
}

@MainActor
private func clockFields(in view: NSView) -> [NSTextField] {
    if let field = view as? NSTextField, field.cell is ArrivalClockDigitCell { return [field] }
    return view.subviews.flatMap { clockFields(in: $0) }
}

@MainActor
private func checkNaturalFocusTransitions() {
    let draft = Draft()
    let host = NSHostingView(rootView: HStack {
        ForEach(0..<4) { index in
            ArrivalClockDigitField(
                text: Binding(get: { draft.edit.digits[index] }, set: { draft.edit.replaceDigit(at: index, with: $0) }),
                focusedDigit: Binding(get: { draft.focus }, set: { draft.focus = $0 }),
                index: index, color: .labelColor, label: "Digit \(index)",
                onPaste: { draft.edit.replaceDigit(at: index, with: $0) }, onSubmit: {}, onCancel: {})
                .frame(width: 20, height: 34)
        }
    })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    host.layoutSubtreeIfNeeded()
    let fields = clockFields(in: host).sorted { $0.accessibilityLabel()! < $1.accessibilityLabel()! }
    precondition(fields.count == 4 && window.makeFirstResponder(fields[0]))
    precondition(draft.focus == 0, "Initial responder focus was not recorded before typing")
    let firstEditor = fields[0].currentEditor() as! NSTextView
    firstEditor.insertText("2", replacementRange: NSRange(location: 0, length: 1))
    precondition(draft.focus == 0 && draft.edit.digits[0] == "2", "Natural typing did not begin editing")
    precondition(window.makeFirstResponder(fields[1]))
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    precondition(draft.focus == 1 && fields[1].currentEditor() != nil,
                 "Moving after typing lost focus before the next digit received text")
    (fields[1].currentEditor() as! NSTextView).doCommand(by: #selector(NSResponder.insertTab(_:)))
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    precondition(draft.focus == 2 && fields[2].currentEditor() != nil, "Tab to an untyped digit lost editing focus")
    (fields[2].currentEditor() as! NSTextView).doCommand(by: #selector(NSResponder.insertBacktab(_:)))
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    precondition(draft.focus == 1 && fields[1].currentEditor() != nil, "Shift-Tab to an untyped digit lost editing focus")
    precondition(window.makeFirstResponder(nil))
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    precondition(draft.focus == nil, "Leaving an untyped digit did not signal editor exit")
    for (index, command) in [(0, #selector(NSResponder.insertBacktab(_:))), (3, #selector(NSResponder.insertTab(_:)))] {
        precondition(window.makeFirstResponder(fields[index]))
        (fields[index].currentEditor() as! NSTextView).doCommand(by: command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        precondition(draft.focus == nil && fields[index].currentEditor() == nil, "Tab at the clock boundary trapped focus")
    }
    print("PASS natural digit focus: actual typing, first-responder move without typing, Tab, run-loop pause and editor exit")
}

@main
struct ClockPasteProbe {
    @MainActor static func main() {
        _ = NSApplication.shared
        checkNaturalFocusTransitions()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        for index in 0..<4 {
            for (input, expected) in [("1234", "12:34"), ("12:34", "12:34"), ("1231", "12:31"), ("12:31", "12:31")] {
                for selection in [NSRange(location: 0, length: 0), NSRange(location: 1, length: 0), NSRange(location: 0, length: 1)] {
                    for plainText in [false, true] {
                        let draft = Draft()
                        let view = ArrivalClockDigitField(
                            text: Binding(get: { draft.edit.digits[index] }, set: { draft.edit.replaceDigit(at: index, with: $0) }),
                            focusedDigit: Binding(get: { draft.focus }, set: { draft.focus = $0 }),
                            index: index, color: .labelColor, label: "Clock digit \(index)",
                            onPaste: { draft.edit.replaceDigit(at: index, with: $0) },
                            onSubmit: { draft.submits += 1 }, onCancel: { draft.cancels += 1 })
                        let host = NSHostingView(rootView: view.frame(width: 20, height: 34))
                        window.contentView = host
                        host.layoutSubtreeIfNeeded()
                        guard let field = textField(in: host), field.isEditable, field.isSelectable,
                              window.makeFirstResponder(field),
                              let editor = field.currentEditor() as? ArrivalClockFieldEditor,
                              let coordinator = field.delegate as? ArrivalClockDigitField.Coordinator else {
                            preconditionFailure("Digit field did not install its native paste editor/delegate")
                        }
                        var reads = 0
                        editor.readPasteboard = { reads += 1; return input }
                        precondition(reads == 0, "Field creation read the clipboard")
                        editor.string = "1"
                        editor.setSelectedRange(selection)
                        if plainText { editor.pasteAsPlainText(nil) } else { editor.paste(nil) }
                        precondition(draft.edit.text == expected && reads == 1, "Native paste lost raw text or inferred the old digit")
                        precondition(field.stringValue == draft.edit.digits[index], "Paste left the active field stale")
                        editor.readPasteboard = { nil }
                        editor.paste(nil)
                        precondition(draft.edit.text == expected, "An unavailable clipboard changed the draft")
                        for insertBefore in [true, false] {
                            let old = draft.edit.digits[index]
                            field.stringValue = insertBefore ? "5" + old : old + "5"
                            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
                            precondition(draft.edit.digits[index] == "5", "Native typing did not replace one digit")
                        }
                        field.stringValue = ""
                        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
                        field.stringValue = "x"
                        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
                        precondition(draft.edit.digits[index].isEmpty && field.stringValue.isEmpty, "Clearing or invalid-input rejection changed")
                        precondition(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
                        precondition(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
                        precondition(draft.submits == 1 && draft.cancels == 1)
                        precondition(field.accessibilityLabel() == "Clock digit \(index)")
                    }
                }
            }
        }
        print("PASS native clock paste: four fields, raw/colon and overlapping digits, both caret positions/selection, paste/plain text, no eager clipboard reads, typing/clear/invalid input, focus/autosave, Return/Escape/Tab and accessibility")
    }
}
