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

@MainActor
private final class TerminationProbe: NSObject, NSApplicationDelegate {
    var requests = 0
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requests += 1
        return .terminateCancel
    }
}

@MainActor
private final class MenuTrackingProbe: NSObject {
    var menu: NSMenu?
    @objc func didBeginTracking(_ notification: Notification) {
        menu = notification.object as? NSMenu
        DispatchQueue.main.async {
            if let output = ProcessInfo.processInfo.environment["HAPPY_LULU_PANEL_CAPTURE_OUTPUT"] {
                do {
                    let directory = URL(fileURLWithPath: output, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for (index, window) in NSApplication.shared.windows.enumerated() where window.isVisible {
                        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        let filename = "panel-more-\(AppLanguage.shared.choice.rawValue)-\(index)-\(String(describing: type(of: window))).png"
                        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
                    }
                } catch { preconditionFailure("Could not capture isolated menu: \(error)") }
            }
            self.menu?.cancelTracking()
        }
    }
}

@MainActor
private func openHeaderMenu(in host: NSView, window: NSWindow, at point: NSPoint = NSPoint(x: 334, y: 30)) -> NSMenu? {
    let observation = MenuTrackingProbe()
    NotificationCenter.default.addObserver(observation, selector: #selector(MenuTrackingProbe.didBeginTracking(_:)),
                                           name: NSMenu.didBeginTrackingNotification, object: nil)
    defer { NotificationCenter.default.removeObserver(observation) }
    let location = host.convert(point, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        window.sendEvent(event)
    }
    pump(host)
    return observation.menu
}

@main
struct PanelFocusProbe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let identity = Bundle.main.bundleIdentifier!
        precondition(identity == "test.happylulu.panel-focus-probe")
        defer { UserDefaults.standard.removePersistentDomain(forName: identity) }
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
        var settingsOpens = 0
        let panel = PanelView(model: model, calendarSync: sync, plugins: manager,
                              onOpenHistory: {}, onOpenSettings: { settingsOpens += 1 })
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
        let beforeMenus = try Data(contentsOf: store.url)
        for point in [NSPoint(x: 321, y: 17), NSPoint(x: 347, y: 43)] {
            precondition(openHeaderMenu(in: host, window: window, at: point) != nil,
                         "More menu must preserve the full 28-point header hit target")
        }
        for (language, titles) in [(LanguageChoice.english, ["Settings", "Quit"]), (.korean, ["설정", "종료"])] {
            AppLanguage.shared.select(language)
            pump(host)
            let opensBeforeMenu = settingsOpens
            let menu = openHeaderMenu(in: host, window: window)
            precondition(settingsOpens == opensBeforeMenu,
                         "Header control opened Settings directly instead of presenting the more menu")
            precondition(menu != nil, "Header control did not open a native menu")
            let items = menu!.items.filter { !$0.isSeparatorItem }
            precondition(items.map(\.title) == titles, "More menu must expose localized Settings and Quit only")
            menu!.performActionForItem(at: menu!.index(of: items[0]))
            pump(host)
            precondition(settingsOpens == opensBeforeMenu + 1, "Settings menu item did not use the panel callback")
            let termination = TerminationProbe()
            NSApplication.shared.delegate = termination
            menu!.performActionForItem(at: menu!.index(of: items[1]))
            pump(host)
            precondition(termination.requests == 1, "Quit menu item did not request graceful application termination")
            NSApplication.shared.delegate = nil
        }
        let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: image)
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor {
            image.colorAt(x: Int(x * CGFloat(image.pixelsWide) / host.bounds.width),
                          y: Int(y * CGFloat(image.pixelsHigh) / host.bounds.height))!.usingColorSpace(.deviceRGB)!
        }
        let background = color(310, 22)
        for x in [CGFloat(324), 334, 344] {
            let buttonBackground = color(x, 22)
            precondition(abs(buttonBackground.redComponent - background.redComponent) < 0.03 &&
                         abs(buttonBackground.greenComponent - background.greenComponent) < 0.03 &&
                         abs(buttonBackground.blueComponent - background.blueComponent) < 0.03,
                         "More menu trigger must preserve the transparent header background")
        }
        let afterMenus = try Data(contentsOf: store.url)
        precondition(afterMenus == beforeMenus, "Menu changed attendance")
        print("PASS real PanelView more menu: 28-point transparent trigger, Korean/English Settings/Quit, Settings callback, graceful Quit cancelled by isolated probe delegate")
        print("PASS real PanelView focus [host \(ProcessInfo.processInfo.environment["TZ"] ?? "default"), fixture \(timeZone.identifier)]: fixed Friday 16:00, 07:59/08:11 future guards, actual first-digit typing, internal move/pause, production Tab/pause, no intermediate writes, outside click closes and persists once")
    }
}
