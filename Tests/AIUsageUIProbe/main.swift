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

@main
struct AIUsageUIProbe {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(Bundle.main.bundleIdentifier!.hasPrefix("local.happylulu.usage-probe."))
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
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
        let panel = PanelView(model: model, calendarSync: sync, plugins: plugins,
            onOpenHistory: {}, onOpenSettings: {})
        for theme in [AppearancePalette.softMint, .charcoal] {
            AppearanceModel.shared.selectPalette(theme)
            let suffix = theme == .softMint ? "light" : "dark"
            let scheme: ColorScheme = theme == .softMint ? .light : .dark
            navigation.selection = .general
            plugins.setShowUsage(false)
            try await render(settings, size: NSSize(width: 920, height: 760), name: "general-off-" + suffix,
                directory: output, scheme: scheme)
            plugins.setShowUsage(true)
            let deadline = Date().addingTimeInterval(3)
            while PreviewUsageModule.model.snapshot == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            precondition(plugins.menuBarItems.first?.title == "Codex 72%")
            navigation.pluginID = AIUsageModule.id; navigation.selection = .plugin
            try await render(settings, size: NSSize(width: 820, height: 700), name: "usage-settings-" + suffix,
                directory: output, scheme: scheme)
            try await render(panel, size: NSSize(width: 364, height: 390), name: "panel-" + suffix,
                directory: output, scheme: scheme)
        }
        plugins.setShowUsage(false); plugins.stop()
        precondition(plugins.menuBarItems.isEmpty && !PreviewUsageModule.model.isRunning)
        let after = try Data(contentsOf: store.url)
        precondition(before == after && !sync.runtimeAllowed)
        print("PASS usage UI: actual settings/panel, isolated synthetic 72% fixture, light/dark, display-off, stop and unchanged attendance")
    }
    @MainActor private static func render<V: View>(_ view: V, size: NSSize, name: String,
        directory: URL, scheme: ColorScheme) async throws {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        window.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
}
