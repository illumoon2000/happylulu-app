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
        checkPlacement()
        for usesMenuBarPanel in [false, true] {
            try checkFocus(root: root.appendingPathComponent(usesMenuBarPanel ? "arrowless" : "legacy"),
                           timeZone: timeZone, usesMenuBarPanel: usesMenuBarPanel)
        }
    }

    @MainActor private static func checkPlacement() {
        let cases: [(String, NSRect, NSRect, NSRect)] = [
            ("center", NSRect(x: 700, y: 876, width: 40, height: 24),
             NSRect(x: 0, y: 0, width: 1440, height: 876), NSRect(x: 538, y: 520, width: 364, height: 350)),
            ("left edge", NSRect(x: 0, y: 876, width: 24, height: 24),
             NSRect(x: 0, y: 0, width: 1440, height: 876), NSRect(x: 8, y: 520, width: 364, height: 350)),
            ("right edge", NSRect(x: 1408, y: 876, width: 32, height: 24),
             NSRect(x: 0, y: 0, width: 1440, height: 876), NSRect(x: 1068, y: 520, width: 364, height: 350)),
            ("negative-coordinate monitor", NSRect(x: -1640, y: 1080, width: 40, height: 24),
             NSRect(x: -1920, y: 23, width: 1920, height: 1057), NSRect(x: -1802, y: 724, width: 364, height: 350)),
            ("raised secondary monitor", NSRect(x: 1940, y: 1900, width: 40, height: 24),
             NSRect(x: 1440, y: 900, width: 1280, height: 1000), NSRect(x: 1778, y: 1544, width: 364, height: 350)),
            ("dock reduces usable frame", NSRect(x: 1408, y: 876, width: 32, height: 24),
             NSRect(x: 0, y: 70, width: 1380, height: 806), NSRect(x: 1008, y: 520, width: 364, height: 350)),
            ("compact usable frame", NSRect(x: 130, y: 240, width: 40, height: 24),
             NSRect(x: 0, y: 0, width: 300, height: 240), NSRect(x: 8, y: 8, width: 284, height: 226)),
            ("anchor below visible top", NSRect(x: 700, y: 850, width: 40, height: 24),
             NSRect(x: 0, y: 0, width: 1440, height: 876), NSRect(x: 538, y: 494, width: 364, height: 350))
        ]
        for (name, anchor, visible, expected) in cases {
            let frame = MenuBarPanel.frame(anchor: anchor, visibleFrame: visible, size: NSSize(width: 364, height: 350))
            precondition(frame == expected && visible.contains(frame), "Wrong menu-panel placement: \(name), \(frame)")
        }
        print("PASS menu-panel placement: 8 center/edge/multi-monitor/dock/compact-frame cases")
    }

    @MainActor private static func checkFocus(root: URL, timeZone: TimeZone, usesMenuBarPanel: Bool) throws {
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
        let controller = NSHostingController(rootView: panel)
        let host = controller.view
        let popup = usesMenuBarPanel ? MenuBarPanel(content: controller) : nil
        let window: NSWindow = popup ?? NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 364, height: 350),
                                                styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // A transparent synthetic anchor stays on a real display so window.screen is
        // available. No actual NSStatusItem or production menu-bar icon is created.
        let screen = NSScreen.main!
        let anchorWindow = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 60,
                                                       width: 40, height: 24),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        anchorWindow.alphaValue = 0
        let anchor = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        anchorWindow.contentView = anchor
        if let popup {
            anchorWindow.orderFront(nil)
            popup.show(relativeTo: anchor)
            let top = popup.frame.maxY
            for height in [CGFloat(390), 430, 350] {
                popup.updateContentSize(NSSize(width: 364, height: height))
                precondition(popup.frame.height == height && abs(popup.frame.maxY - top) < 0.5,
                             "Usage rows must resize the popup while keeping its menu-bar anchor")
            }
            print("PASS arrowless size: usage off/on/two rows keeps the top anchor")
            popup.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            precondition(popup.isVisible && popup.contentViewController === controller && popup.canBecomeKey,
                         "Arrowless host did not show its production content")
        } else {
            window.contentViewController = controller
            window.orderFront(nil)
        }
        defer {
            popup?.dismiss()
            window.orderOut(nil)
            anchorWindow.orderOut(nil)
            anchorWindow.close()
        }
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
        if let popup {
            func reopenedFields() -> [NSTextField] {
                popup.show(relativeTo: anchor)
                popup.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                pump(host)
                precondition(popup.isVisible && popup.contentViewController === controller)
                return descendants(host).compactMap { $0 as? NSTextField }.filter { $0.cell is ArrivalClockDigitCell }
                    .sorted { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x }
            }
            popup.dismiss()
            pump(host)
            precondition(!popup.isVisible && popup.contentViewController == nil && saves == 1)
            let cancelledFields = reopenedFields()
            precondition(cancelledFields.map { $0.stringValue } == ["0", "8", "1", "2"],
                         "Reopening retained stale clock text")
            precondition(popup.makeFirstResponder(cancelledFields[0]))
            let cancelEditor = cancelledFields[0].currentEditor() as! ArrivalClockFieldEditor
            cancelEditor.readPasteboard = { "08:13" }
            cancelEditor.paste(nil)
            cancelEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            pump(host)
            precondition(popup.isVisible && saves == 1 &&
                         descendants(host).allSatisfy { !(($0 as? NSTextField)?.cell is ArrivalClockDigitCell) },
                         "Editor Escape must cancel the draft without dismissing the panel or saving")
            popup.dismiss()
            pump(host)
            let dismissedFields = reopenedFields()
            precondition(dismissedFields.map { $0.stringValue } == ["0", "8", "1", "2"])
            precondition(popup.makeFirstResponder(dismissedFields[0]))
            let dismissEditor = dismissedFields[0].currentEditor() as! ArrivalClockFieldEditor
            dismissEditor.readPasteboard = { "08:14" }
            dismissEditor.paste(nil)
            pump(host)
            precondition(saves == 1, "Pasting into the popup saved before dismissal")
            popup.dismiss()
            pump(host)
            let dismissedState = try store.load()
            precondition(!popup.isVisible && popup.contentViewController == nil && saves == 2 &&
                         Attendance.clockLabel(dismissedState.arrivals[model.dayKey(model.now)]!.time,
                                               timeZone: timeZone) == "08:14",
                         "Dismissing a focused popup must persist its edited clock exactly once")
            let afterDismiss = try Data(contentsOf: store.url)
            popup.dismiss()
            pump(host)
            let afterRepeatedDismiss = try Data(contentsOf: store.url)
            precondition(saves == 2 && afterRepeatedDismiss == afterDismiss)
            let finalFields = reopenedFields()
            precondition(finalFields.map { $0.stringValue } == ["0", "8", "1", "4"] && saves == 2,
                         "Reopened popup did not restore the just-saved time")
            popup.cancelOperation(nil)
            pump(host)
            precondition(!popup.isVisible && saves == 2, "Panel fallback Escape did not dismiss without another save")
            print("PASS arrowless lifecycle: editor Escape cancels, dismiss saves once, repeated dismiss is inert, reopening restores state, panel Escape closes")
        }
        withExtendedLifetime(observation) {}
        if let popup {
            popup.show(relativeTo: anchor)
            popup.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            pump(host)
        }
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
