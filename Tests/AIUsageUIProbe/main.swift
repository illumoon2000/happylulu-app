import AppKit
import SwiftUI
import AppPluginCore
import AppPluginHost
import AfterSixCore
import AIUsagePlugin
import AIUsageIntegration

private struct PreviewUsageProvider: UsageProvider {
    let name = "Codex"
    func fetch() async throws -> UsageSnapshot {
        UsageSnapshot(weekly: UsageWindow(usedPercent: 28, windowDurationMins: 10080,
            resetsAt: Date().addingTimeInterval(5 * 86400).timeIntervalSince1970), accountKey: "synthetic-fixture")
    }
    func makeLoginAttempt() -> (any UsageLoginAttempt)? { nil }
}

@MainActor
private enum PreviewUsageModule: PluginModule {
    static let id = AIUsageModule.id
    static var catalogMetadata: PluginModuleMetadata? { AIUsageModule.catalogMetadata }
    static var model: AIUsageModel!
    static func register(in context: PluginHostContext) throws {
        let model = AIUsageModel(localize: context.localize, providerFactory: { _ in PreviewUsageProvider() })
        self.model = model
        let adapter = SnapshotFeatureAdapter(descriptor: FeatureAdapterDescriptor(id: id, name: id, features: []),
            api: context.registry, timeZone: .current)
        try context.register(PluginRegistration(controller: model, adapter: adapter, symbol: "gauge", summary: "Fixture",
            setEnabled: model.setEnabled))
        try context.presentations.register(id) { AIUsageSettingsView(model: model) }
    }
}

@MainActor
private final class UsageProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            do { try await AIUsageUIProbe.check(); exit(0) }
            catch { print("FAIL usage UI: \(error)"); exit(1) }
        }
    }
}

@MainActor
private final class UsageMenuObservation: NSObject {
    var menu: NSMenu?
    @objc func didBeginTracking(_ notification: Notification) {
        menu = notification.object as? NSMenu
        DispatchQueue.main.async { self.menu?.cancelTracking() }
    }
}

@MainActor
private final class UsageRoutingObservation { var openedPlugin: String? }

@main
struct AIUsageUIProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = UsageProbeDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor static func check() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(Bundle.main.bundleIdentifier!.hasPrefix("local.happylulu.usage-probe."))
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.mainMenu = makeApplicationMenu()
        precondition(Bundle.main.url(forResource: "HappyLuluBrand", withExtension: "png") != nil)
        for state in LuluDisplayState.allCases {
            precondition(Bundle.main.url(forResource: state.rawValue, withExtension: "png", subdirectory: "OwlStates") != nil)
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!) }
        AppLanguage.shared.select(.korean)
        let store = StateStore(url: output.appendingPathComponent("attendance.json"))
        var state = AttendanceState(); state.didOfferLoginItem = true; state.detectHalfDaysFromCalendar = false
        try store.save(state)
        let before = try Data(contentsOf: store.url)
        let sync = CalendarSyncModel(runtimeAllowed: false, storeURL: output.appendingPathComponent("calendar.sqlite"))
        let plugins = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(),
            routingStore: FeatureRoutingStore(url: nil), catalogStore: PluginCatalogStore(url: nil))
        let presentations = PluginSettingsPresentationRegistry()
        plugins.configureCatalog(sync: sync, presentations: presentations, modules: [PreviewUsageModule.self])
        plugins.start()
        let model = AppModel(store: store, featureRouter: plugins.router, allowsLoginItemChanges: false)
        let navigation = SettingsNavigation()
        let settings = SettingsView(model: model, updater: AppUpdater(), calendarSync: sync, plugins: plugins,
            featureCalendar: FeatureCalendarModel(router: plugins.router), pluginPresentations: presentations, navigation: navigation)
        let routing = UsageRoutingObservation()
        let panel = PanelView(model: model, calendarSync: sync, plugins: plugins,
            onOpenHistory: {}, onOpenSettings: {}, onOpenPlugin: { routing.openedPlugin = $0 })
        var variants: [(AppearancePalette, ColorScheme, String)] = [(.softMint, .light, "light"), (.charcoal, .dark, "dark")]
        if AppearanceModel.supportsNativeAppearance {
            variants += [(.nativeGlass, .light, "native-light"), (.nativeGlass, .dark, "native-dark")]
        }
        for (theme, scheme, suffix) in variants {
            application.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            AppearanceModel.shared.selectPalette(theme)
            navigation.selection = .general
            plugins.setShowUsage(false)
            try await render(settings, size: NSSize(width: 920, height: 720), name: "general-off-" + suffix,
                directory: output, scheme: scheme)
            try await render(settings, size: NSSize(width: 820, height: 620), name: "general-off-minimum-" + suffix,
                directory: output, scheme: scheme)
            plugins.setShowUsage(true)
            let deadline = Date().addingTimeInterval(3)
            while PreviewUsageModule.model.snapshot == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            precondition(plugins.menuBarItems.first?.title == "Codex 72%")
            try await render(settings, size: NSSize(width: 820, height: 620), name: "general-on-minimum-" + suffix,
                directory: output, scheme: scheme)
            navigation.pluginID = AIUsageModule.id; navigation.selection = .plugin
            try await render(settings, size: NSSize(width: 820, height: 700), name: "usage-settings-" + suffix,
                directory: output, scheme: scheme)
            routing.openedPlugin = nil
            try await render(panel, size: NSSize(width: 364, height: 390), name: "panel-" + suffix,
                directory: output, scheme: scheme, routing: routing)
            precondition(routing.openedPlugin == AIUsageModule.id, "Usage row must open its plugin settings")
        }
        plugins.setShowUsage(false); plugins.stop()
        precondition(plugins.menuBarItems.isEmpty && !PreviewUsageModule.model.isRunning)
        let after = try Data(contentsOf: store.url)
        precondition(before == after && !sync.runtimeAllowed)
        print("PASS usage UI: existing/native light/dark, actual host settings and 390pt menu panel, usage-row routing and Settings/Quit menu, synthetic 72%, display off/on, stop and unchanged attendance")
    }
    @MainActor private static func render<V: View>(_ view: V, size: NSSize, name: String,
        directory: URL, scheme: ColorScheme, routing: UsageRoutingObservation? = nil) async throws {
        let controller = NSHostingController(rootView: view)
        let isPanel = name.hasPrefix("panel-")
        let window: NSWindow = isPanel && LuluGlass.isSupported
            ? MenuBarPanel(content: controller, size: size)
            : NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        let chrome = isPanel ? nil : SettingsWindowChrome(window: window, appearance: .shared)
        defer { withExtendedLifetime(chrome) {}; window.orderOut(nil); window.contentViewController = nil; window.close() }
        let host = controller.view
        let live = ProcessInfo.processInfo.environment["HAPPY_LULU_USAGE_LIVE"] == "1"
            && name.contains("native-") && !name.hasPrefix("general-")
        if live { window.center() }
        else { window.setFrameOrigin(NSPoint(x: -10000, y: -10000)) }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        window.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        if live && CGPreflightScreenCaptureAccess() {
            let screenshot = directory.appendingPathComponent(name + ".window.png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), screenshot.path]
            try process.run(); process.waitUntilExit()
            precondition(process.terminationStatus == 0)
            print("PASS usage live capture: \(screenshot.lastPathComponent)")
        }
        if let routing {
            let point = host.convert(NSPoint(x: 180, y: 251), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(50))
            precondition(routing.openedPlugin == AIUsageModule.id, "Usage row click must reach the plugin callback")
            // AppKit menu placement requires an on-screen anchor, even when
            // the rest of this synthetic fixture is rendered offscreen.
            window.center()
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            let menuObservation = UsageMenuObservation()
            NotificationCenter.default.addObserver(menuObservation, selector: #selector(UsageMenuObservation.didBeginTracking(_:)),
                name: NSMenu.didBeginTrackingNotification, object: nil)
            defer { NotificationCenter.default.removeObserver(menuObservation) }
            let menuPoint = host.convert(NSPoint(x: 334, y: 30), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: menuPoint, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(50))
            let menuTitles = menuObservation.menu?.items.filter { !$0.isSeparatorItem }.map(\.title)
            precondition(menuTitles == ["설정", "종료"],
                         "Settings/Quit menu missing for \(name): \(String(describing: menuTitles)); visible=\(window.isVisible), key=\(window.isKeyWindow)")
            print("PASS usage panel menu and routing: \(name)")
        }
    }
}
