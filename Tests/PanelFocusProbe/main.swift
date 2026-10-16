import AppKit
import SwiftUI
import Combine
import AfterSixCore
import AppPluginCore

@MainActor
private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

@MainActor
private func pump(_ host: NSView) {
    // UI delivery waits use elapsed wall time; attendance uses the injected fixture clock.
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    host.layoutSubtreeIfNeeded()
}

@main
struct PanelFocusProbe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let timeZone = TimeZone(identifier: CommandLine.arguments[2])!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let fixtureCalendar = calendar
        var fixtureNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 7, minute: 59))!
        let store = StateStore(url: root.appendingPathComponent("state.json"))
        let manager = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(), routingStore: FeatureRoutingStore(url: nil))
        let model = AppModel(store: store, featureRouter: manager.router, allowsLoginItemChanges: false,
                             nowProvider: { fixtureNow }, calendarProvider: { fixtureCalendar })
        precondition(model.now == fixtureNow && model.calendar.timeZone == timeZone,
                     "AppModel initialization ignored the fixture clock/calendar")
        precondition(!model.saveManualClockText("08:00", forDay: model.dayKey(model.now)) && model.state.arrivals.isEmpty,
                     "07:59 fixture must reject a future 08:00 arrival")
        fixtureNow = calendar.date(bySettingHour: 8, minute: 11, second: 0, of: fixtureNow)!
        model.refresh()
        precondition(model.saveManualClockText("08:11", forDay: model.dayKey(model.now)))
        let original = try Data(contentsOf: store.url)
        precondition(!model.saveManualClockText("08:12", forDay: model.dayKey(model.now)),
                     "08:11 fixture must reject a future 08:12 arrival")
        let afterFuture = try Data(contentsOf: store.url)
        precondition(afterFuture == original && model.now == fixtureNow,
                     "Rejected future time changed attendance or escaped the fixture clock")
        fixtureNow = calendar.date(bySettingHour: 16, minute: 0, second: 0, of: fixtureNow)!
        model.refresh()
        precondition(model.now == fixtureNow && model.dayKey(model.now) == "2026-10-16")
        let sync = CalendarSyncModel(runtimeAllowed: false, storeURL: root.appendingPathComponent("sync.sqlite"))
        let panel = PanelView(model: model, calendarSync: sync, plugins: manager, onOpenHistory: {}, onOpenSettings: {})
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 364, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        pump(host)
        let fields = descendants(host).compactMap { $0 as? NSTextField }.filter { $0.cell is ArrivalClockDigitCell }
            .sorted { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x }
        precondition(fields.count == 4, "Panel did not enter its four-digit editor")
        precondition(fields.map { $0.stringValue } == ["0", "8", "1", "1"] && model.now == fixtureNow,
                     "Panel onAppear/beginEditing refresh ignored the fixture clock")
        var saves = 0
        let observation = model.$state.dropFirst().sink { _ in saves += 1 }
        precondition(window.makeFirstResponder(fields[0]))
        let editor = fields[0].currentEditor() as! NSTextView
        editor.insertText("0", replacementRange: NSRange(location: 0, length: 1))
        precondition(window.makeFirstResponder(fields[1]))
        pump(host)
        precondition(descendants(host).filter { ($0 as? NSTextField)?.cell is ArrivalClockDigitCell }.count == 4,
                     "Panel autosaved and closed after moving to an untyped digit")
        precondition(fields[1].currentEditor() != nil && saves == 0, "Panel moved focus away or saved during an internal move")
        (fields[1].currentEditor() as! NSTextView).doCommand(by: #selector(NSResponder.insertTab(_:)))
        pump(host)
        precondition(fields[2].currentEditor() != nil && saves == 0, "Production Tab traversal did not retain the next untyped digit")
        (fields[2].currentEditor() as! NSTextView).doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        pump(host)
        precondition(fields[1].currentEditor() != nil && saves == 0, "Production Shift-Tab closed the editor")
        let afterMoves = try Data(contentsOf: store.url)
        precondition(afterMoves == original, "Internal focus movement wrote attendance")
        let pasteEditor = fields[1].currentEditor() as! ArrivalClockFieldEditor
        pasteEditor.readPasteboard = { "08:12" }
        pasteEditor.paste(nil)
        pump(host)
        let point = NSPoint(x: host.bounds.maxX - 4, y: host.bounds.maxY - 4)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: host.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApplication.shared.sendEvent(event)
        pump(host)
        precondition(descendants(host).allSatisfy { !(($0 as? NSTextField)?.cell is ArrivalClockDigitCell) },
                     "Outside click did not close the real editor")
        precondition(saves == 1 && model.errorMessage == nil, "Outside click did not commit attendance exactly once")
        let persisted = try store.load()
        let arrival = persisted.arrivals[model.dayKey(model.now)]!
        precondition(Attendance.clockLabel(arrival.time, timeZone: model.calendar.timeZone) == "08:12")
        precondition(model.now == fixtureNow && arrival.day == "2026-10-16",
                     "Final panel save escaped the fixed weekday clock")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        NSApplication.shared.sendEvent(event)
        pump(host)
        let repeated = try FileManager.default.attributesOfItem(atPath: store.url.path)
        precondition(saves == 1 && attributes[.systemFileNumber] as? NSNumber == repeated[.systemFileNumber] as? NSNumber &&
                     attributes[.modificationDate] as? Date == repeated[.modificationDate] as? Date,
                     "Repeated outside click saved the same draft again")
        withExtendedLifetime(observation) {}
        print("PASS real PanelView focus [host \(ProcessInfo.processInfo.environment["TZ"] ?? "default"), fixture \(timeZone.identifier)]: fixed Friday 16:00, 07:59/08:11 future guards, actual first-digit typing, internal move/pause, production Tab/pause, no intermediate writes, outside click closes and persists once")
    }
}
