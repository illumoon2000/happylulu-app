import AppKit
import SwiftUI
import AfterSixCore
import AppPluginHost

@MainActor
private final class MaterialObservation {
    var enabled: Bool?
}

@MainActor
private struct MaterialObserver: View {
    private var glass = LuluGlass()
    let observation: MaterialObservation

    init(observation: MaterialObservation) {
        self.observation = observation
    }
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .onAppear { observation.enabled = glass.isEnabled }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private func requestedMaterialMode() -> LuluMaterialMode {
    switch ProcessInfo.processInfo.environment["HAPPY_LULU_MATERIAL_MODE"] ?? "automatic" {
    case "automatic": .automatic
    case "legacy": .legacy
    default: fatalError("HAPPY_LULU_MATERIAL_MODE must be automatic or legacy")
    }
}

@MainActor
private func pump(_ host: NSView) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
}

@MainActor
private func click(_ point: NSPoint, in host: NSView, window: NSWindow, tracksMouse: Bool = false) {
    let location = host.convert(point, to: nil)
    let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }
    if tracksMouse {
        // A native table may consume mouseUp in its synchronous mouseDown tracking loop.
        NSApp.postEvent(events[1], atStart: true)
        window.sendEvent(events[0])
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            window.sendEvent(release)
        }
    } else {
        events.forEach { window.sendEvent($0) }
    }
    pump(host)
}

@MainActor
private func tables(in view: NSView) -> [NSTableView] {
    (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
}

@MainActor
private func arrow(_ keyCode: UInt16, character: Int, host: NSView, window: NSWindow) {
    let characters = String(UnicodeScalar(character)!)
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode)!
        window.sendEvent(event)
    }
    pump(host)
}

@MainActor
private func bitmap(_ host: NSView) -> NSBitmapImageRep {
    host.layoutSubtreeIfNeeded()
    let result = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: result)
    return result
}

@MainActor
private final class NavigationProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            do { try SettingsNavigationProbe.check(); exit(0) }
            catch { print("FAIL settings navigation: \(error)"); exit(1) }
        }
    }
}

@main
struct SettingsNavigationProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = NavigationProbeDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor static func check() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let identity = Bundle.main.bundleIdentifier!
        precondition(identity.hasPrefix("local.happylulu.navigation-probe."))
        defer { UserDefaults.standard.removePersistentDomain(forName: identity) }
        AppLanguage.shared.select(.english)
        let store = StateStore(url: root.appendingPathComponent("attendance.json"))
        var state = AttendanceState()
        state.didOfferLoginItem = true
        state.detectHalfDaysFromCalendar = false
        try store.save(state)
        let original = try Data(contentsOf: store.url)
        let sync = CalendarSyncModel(runtimeAllowed: false, storeURL: root.appendingPathComponent("sync.sqlite"))
        let plugins = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(),
            routingStore: FeatureRoutingStore(url: nil), catalogStore: PluginCatalogStore(url: nil))
        let presentations = PluginSettingsPresentationRegistry()
        plugins.configureCatalog(sync: sync, presentations: presentations, modules: [], allowsExternalIntegrations: false)
        plugins.install("mac-calendar")
        plugins.install("leave-detection")
        let model = AppModel(store: store, featureRouter: plugins.router, allowsLoginItemChanges: false)
        let navigation = SettingsNavigation()
        let materialObservation = MaterialObservation()
        let view = SettingsView(model: model, updater: AppUpdater(), calendarSync: sync, plugins: plugins,
            featureCalendar: FeatureCalendarModel(router: plugins.router), pluginPresentations: presentations,
            navigation: navigation)
            .overlay(alignment: .bottomTrailing) { MaterialObserver(observation: materialObservation) }
            .environment(\.luluMaterialMode, requestedMaterialMode())
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        pump(host)
        guard let glassEnabled = materialObservation.enabled else {
            fatalError("Hosted material environment must be observed before selecting click coordinates")
        }
        let sidebarInset: CGFloat = glassEnabled ? 10 : 0
        func measure(_ name: String, change: () -> Void) {
            let start = DispatchTime.now().uptimeNanoseconds
            change()
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            _ = bitmap(host)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            print(String(format: "MEASURE %@ %.2f ms", name, ms))
        }
        print("Fixture OS: \(ProcessInfo.processInfo.operatingSystemVersionString); label-control failures indicate layout drift")
        print("Hosted Liquid Glass enabled: \(glassEnabled); sidebar inset: \(sidebarInset)")
        measure("first-ever-appearance") { navigation.selection = .appearance }
        navigation.selection = .general
        pump(host)
        // These centers come from the fixed 900×700, English legacy SettingsView layout.
        // The supported material layout adds a 10pt outside inset; actual hosted policy selects it.
        // Validate text/icon control clicks too, so layout drift cannot masquerade as a hit-area regression.
        let rows: [(String, SettingsSection, String?, CGFloat)] = [
            ("General", .general, nil, 105), ("Appearance", .appearance, nil, 142),
            ("Work", .work, nil, 179), ("Arrival history", .history, nil, 216),
            ("Updates", .updates, nil, 253), ("Manage plugins", .plugins, nil, 302),
            ("Calendar", .plugin, "mac-calendar", 399),
            ("Leave recognition", .plugin, "leave-detection", 436)
        ]
        var failures = [String]()
        var attempts = 0
        for (title, section, pluginID, y) in rows {
            var points: [(String, CGFloat, CGFloat)] = [("label", 65, y), ("leading-padding", 12, y), ("trailing-blank", 190, y)]
            if section == .general || pluginID == "mac-calendar" {
                points += [("top-padding", 65, y - 14), ("bottom-padding", 65, y + 14)]
            }
            for (area, x, clickY) in points {
                attempts += 1
                navigation.selection = section == .general ? .appearance : .general
                navigation.pluginID = nil
                pump(host)
                let point = NSPoint(x: x + sidebarInset, y: clickY + sidebarInset)
                click(point, in: host, window: window)
                let passed = navigation.selection == section && navigation.pluginID == pluginID
                print("\(passed ? "PASS" : "FAIL") click \(title) \(area) (\(point.x), \(point.y)) -> \(navigation.selection?.rawValue ?? "nil") plugin=\(navigation.pluginID ?? "nil")")
                if !passed { failures.append("\(title) \(area)") }
            }
        }
        let appearance = AppearanceModel.shared
        var nativeAttempts = 0
        var nativeFailures = [String]()
        if AppearanceModel.supportsNativeAppearance {
            appearance.selectPalette(.nativeGlass)
            window.center()
            window.makeKeyAndOrderFront(nil)
            navigation.selection = .general
            navigation.pluginID = nil
            pump(host)
            let nativeTables = tables(in: host)
            if nativeTables.count == 1, let table = nativeTables.first {
                // Use real native row geometry and group metadata. CLI NSHostingView does
                // not expose SwiftUI AX labels; verify the complete fixture row count first.
                let contentRows = (0..<table.numberOfRows).filter {
                    table.rowView(atRow: $0, makeIfNecessary: true)?.isGroupRowStyle == false
                }
                nativeAttempts += 1
                let shapePassed = contentRows.count == rows.count
                print("\(shapePassed ? "PASS" : "FAIL") native List structure: \(contentRows.count) content rows, expected \(rows.count)")
                if !shapePassed { nativeFailures.append("native row count") }
                if window.isKeyWindow && shapePassed {
                    for (fixture, row) in zip(rows, contentRows) {
                        let (title, section, pluginID, _) = fixture
                        nativeAttempts += 1
                        navigation.selection = section == .general ? .appearance : .general
                        navigation.pluginID = nil
                        pump(host)
                        table.scrollRowToVisible(row)
                        pump(host)
                        let rect = table.rect(ofRow: row)
                        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: host)
                        click(point, in: host, window: window, tracksMouse: true)
                        let passed = navigation.selection == section && navigation.pluginID == pluginID
                        print("\(passed ? "PASS" : "FAIL") native List click \(title) -> \(navigation.selection?.rawValue ?? "nil") plugin=\(navigation.pluginID ?? "nil")")
                        if !passed { nativeFailures.append("native click \(title)") }
                    }
                } else if !window.isKeyWindow {
                    // A headless runner may still deny activation. Do not count synthetic
                    // mouse delivery to an inactive table as integration coverage.
                    print("SKIP native List mouse/window integration: CLI fixture is not a key window")
                }
                navigation.selection = .general
                navigation.pluginID = nil
                pump(host)
                let focused = window.makeFirstResponder(table)
                for section in [SettingsSection.appearance, .work] {
                    nativeAttempts += 1
                    arrow(125, character: NSDownArrowFunctionKey, host: host, window: window)
                    let passed = focused && navigation.selection == section && navigation.pluginID == nil
                    print("\(passed ? "PASS" : "FAIL") native List keyboard down -> \(navigation.selection?.rawValue ?? "nil")")
                    if !passed { nativeFailures.append("native keyboard \(section.rawValue)") }
                }
            } else {
                nativeAttempts += 1
                nativeFailures.append("native sidebar table not found")
                print("FAIL expected one native sidebar table, found \(nativeTables.count)")
            }
            print("RESULT \(nativeAttempts - nativeFailures.count)/\(nativeAttempts) native List navigation checks passed")
            appearance.selectPalette(.offwhiteLilac)
            pump(host)
        } else {
            print("SKIP native List navigation: Liquid Glass theme requires macOS 26 and its SDK")
        }
        let distinct = Set([AppearanceIcon.original, .mint, .blue, .lavender, .graphite].map {
            appearance.image(for: $0).tiffRepresentation!
        })
        precondition(distinct.count == 5, "Graphics context failed to render distinct production icon variants")
        for index in 0..<5 {
            navigation.selection = .general
            pump(host)
            measure("enter-appearance-\(index)") { navigation.selection = .appearance }
        }
        for palette in AppearancePalette.allCases {
            measure("palette-\(palette.rawValue)") { appearance.selectPalette(palette) }
        }
        try bitmap(host).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("settings-appearance.png"))
        navigation.selection = .general
        pump(host)
        try bitmap(host).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("settings-general.png"))
        // CLI hosting on this system exposes no SwiftUI AX descendants; preserve the production
        // .isSelected trait and native Button labels, and report that limit instead of inventing AX coverage.
        print("AX descendants exposed by CLI NSHostingView: \(host.accessibilityChildren()?.count ?? 0)")
        precondition(attempts == 28, "Both layouts must retain all 28 sidebar hit-area checks")
        print("RESULT \(attempts - failures.count)/\(attempts) real sidebar clicks passed; distinct icon variants=\(distinct.count)")
        let after = try Data(contentsOf: store.url)
        precondition(original == after && !sync.runtimeAllowed)
        print("PASS isolated attendance unchanged, calendar runtime disabled, updater never started, login changes disabled")
        if !failures.isEmpty || !nativeFailures.isEmpty { exit(1) }
    }
}
