import AppKit
import SwiftUI
import AfterSixCore
import AppPluginHost

@MainActor
private func pump(_ host: NSView) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
}

@MainActor
private func click(_ point: NSPoint, in host: NSView, window: NSWindow) {
    let location = host.convert(point, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
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

@main
struct SettingsNavigationProbe {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let identity = Bundle.main.bundleIdentifier!
        precondition(identity.hasPrefix("local.happylulu.navigation-probe."))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
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
        let view = SettingsView(model: model, updater: AppUpdater(), calendarSync: sync, plugins: plugins,
            featureCalendar: FeatureCalendarModel(router: plugins.router), pluginPresentations: presentations,
            navigation: navigation)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        pump(host)
        func measure(_ name: String, change: () -> Void) {
            let start = DispatchTime.now().uptimeNanoseconds
            change()
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            _ = bitmap(host)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            print(String(format: "MEASURE %@ %.2f ms", name, ms))
        }
        print("Fixture OS: \(ProcessInfo.processInfo.operatingSystemVersionString); label-control failures indicate layout drift")
        measure("first-ever-appearance") { navigation.selection = .appearance }
        navigation.selection = .general
        pump(host)
        // These centers come from the fixed 900×700, English production SettingsView layout.
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
                click(NSPoint(x: x, y: clickY), in: host, window: window)
                let passed = navigation.selection == section && navigation.pluginID == pluginID
                print("\(passed ? "PASS" : "FAIL") click \(title) \(area) (\(x), \(clickY)) -> \(navigation.selection?.rawValue ?? "nil") plugin=\(navigation.pluginID ?? "nil")")
                if !passed { failures.append("\(title) \(area)") }
            }
        }
        let appearance = AppearanceModel.shared
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
        print("RESULT \(attempts - failures.count)/\(attempts) real sidebar clicks passed; distinct icon variants=\(distinct.count)")
        let after = try Data(contentsOf: store.url)
        precondition(original == after && !sync.runtimeAllowed)
        print("PASS isolated attendance unchanged, calendar runtime disabled, updater never started, login changes disabled")
        if !failures.isEmpty { exit(1) }
    }
}
