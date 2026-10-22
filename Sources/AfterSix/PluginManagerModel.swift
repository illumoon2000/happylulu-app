import Foundation
import Combine
import AppPluginCore
import AppPluginHost

struct FeatureRoutingStore {
    let url: URL?
    static var standard: Self {
        Self(url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AfterSix/Plugins/feature-routing.json"))
    }
    func load() throws -> [AppFeature: String] {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let strings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return try Dictionary(uniqueKeysWithValues: strings.map { key, value in
            guard let feature = AppFeature(rawValue: key), !value.isEmpty else { throw PluginFailure.configuration }
            return (feature, value)
        })
    }
    func save(_ routes: [AppFeature: String]) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let strings = Dictionary(uniqueKeysWithValues: routes.map { ($0.key.rawValue, $0.value) })
        try JSONEncoder().encode(strings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct PluginCatalogEntry: Identifiable {
    let id: String
    let name: String
    let author: String
    let summary: String
    let symbol: String
    let available: Bool
}

struct PluginCatalogState: Codable, Equatable {
    var version = 1
    /// Presence means installed; the value is its independent enabled state.
    var installed: [String: Bool] = [:]
}

struct PluginCatalogStore {
    let url: URL?
    static var standard: Self { Self(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AfterSix/Plugins/catalog.json")) }
    func load() throws -> PluginCatalogState? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(PluginCatalogState.self, from: Data(contentsOf: url))
        guard state.version == 1, state.installed.keys.allSatisfy({ !$0.isEmpty }) else { throw PluginFailure.configuration }
        return state
    }
    func save(_ state: PluginCatalogState) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}

@MainActor
final class PluginManagerModel: ObservableObject {
    let registry: PluginRegistry
    let router: FeatureAdapterRouter
    @Published private(set) var registrations: [PluginRegistration] = []
    @Published private(set) var revision = 0
    @Published private(set) var message: String?
    @Published private(set) var catalog: [PluginCatalogEntry] = []
    @Published private(set) var catalogConfigured = false
    private(set) var leaveDetectionGeneration = 0
    private let catalogStore: PluginCatalogStore
    private var catalogState = PluginCatalogState()
    private var hasCatalogState = false
    private var catalogWritable = true
    private var externalIntegrationsAllowed = true
    var allowsExternalIntegrations: Bool { externalIntegrationsAllowed }
    private var factories: [String: () throws -> Void] = [:]
    var needsLegacyMigration: Bool { !hasCatalogState && catalogWritable }
    var canChangeCatalog: Bool { catalogWritable }
    var installed: [PluginCatalogEntry] { catalog.filter { isInstalled($0.id) } }
    func isInstalled(_ id: String) -> Bool { catalogState.installed[id] != nil }
    func isEnabled(_ id: String) -> Bool { catalogState.installed[id] == true }
    private let routingStore: FeatureRoutingStore
    private var subscriptions: [String: AnyCancellable] = [:]
    private var started = false
    private var savedRoutes: [AppFeature: String] = [:]
    private var writable = true

    init(defaultAdapter: any FeatureAdapter, registry: PluginRegistry = PluginRegistry(),
         routingStore: FeatureRoutingStore = .standard, catalogStore: PluginCatalogStore = PluginCatalogStore(url: nil)) {
        self.registry = registry; self.router = FeatureAdapterRouter(defaultAdapter: defaultAdapter)
        self.routingStore = routingStore
        self.catalogStore = catalogStore
        do {
            if let state = try catalogStore.load() { catalogState = state; hasCatalogState = true }
        } catch {
            catalogWritable = false
            message = "플러그인 상태를 읽지 못했습니다. 원본을 보존하고 읽기 전용으로 실행합니다."
        }
        do { savedRoutes = try routingStore.load() }
        catch {
            writable = false
            if !hasCatalogState { catalogWritable = false }
            message = "기능 연결 설정을 읽지 못했습니다. 원본을 보존하고 기본 연결을 사용합니다."
        }
    }
    func configureCatalog(sync: CalendarSyncModel, presentations: PluginSettingsPresentationRegistry,
                          modules: [any PluginModule.Type] = BundledPlugins.modules,
                          allowsExternalIntegrations: Bool = true) {
        guard !catalogConfigured else { return }
        externalIntegrationsAllowed = allowsExternalIntegrations
        catalogConfigured = true
        catalog = [
            PluginCatalogEntry(id: "mac-calendar", name: L("캘린더", "Calendar"), author: PluginAuthors.contributors,
                summary: L("Mac 캘린더 일정 · 동기화", "Mac calendar events · synchronization"), symbol: "calendar", available: true),
            PluginCatalogEntry(id: "daouoffice", name: L("다우오피스", "Daouoffice"), author: PluginAuthors.daouOffice,
                summary: L("회사 휴가 · 캘린더 일정", "Company leave · calendar events"), symbol: "building.2",
                available: modules.contains { $0.id == "daouoffice" }),
            PluginCatalogEntry(id: "leave-detection", name: L("휴가 자동 인식", "Leave recognition"), author: PluginAuthors.contributors,
                summary: L("연결된 일정의 오전·오후 반차 인식", "Morning/afternoon half-day recognition from connected calendars"),
                symbol: "leaf", available: true),
            PluginCatalogEntry(id: "cpu-runner", name: L("CPU 러너", "CPU Runner"), author: PluginAuthors.contributors,
                summary: L("CPU 사용량에 맞춰 달리는 햄스터·토끼·고양이", "A hamster, rabbit or cat that runs with CPU activity"),
                symbol: "pawprint", available: modules.contains { $0.id == "cpu-runner" })
        ]
        factories["mac-calendar"] = { [weak self, weak sync] in
            guard let self, let sync else { return }
            let controller = LocalPluginController(id: "mac-calendar", name: L("캘린더", "Calendar")) { [weak sync] active in
                sync?.setRuntimeAllowed(active && allowsExternalIntegrations)
            }
            try self.register(PluginRegistration(controller: controller, adapter: MacCalendarFeatureAdapter(sync: sync),
                symbol: "calendar", summary: "Mac 캘린더 일정 · 동기화", setEnabled: controller.setEnabled))
        }
        factories["leave-detection"] = { [weak self] in
            guard let self else { return }
            let controller = LocalPluginController(id: "leave-detection", name: L("휴가 자동 인식", "Leave recognition"))
            try self.register(PluginRegistration(controller: controller, adapter: LeaveDetectionFeatureAdapter(),
                symbol: "leaf", summary: "오전·오후 반차 자동 인식", setEnabled: controller.setEnabled))
        }
        let context = PluginHostContext(registry: registry, presentations: presentations, register: register,
            rollback: rollbackRegistration, localize: L)
        for module in modules where allowsExternalIntegrations { factories[module.id] = { try context.install(module) } }
        for entry in installed where entry.available { activateInstalled(entry.id) }
        revision += 1
    }

    /// The caller supplies only booleans from existing configuration, never credentials.
    func migrateLegacy(calendarConfigured: Bool, daouConfigured: Bool, detectsHalfDays: Bool, hasLegacyAttendance: Bool = false) {
        guard !hasCatalogState, catalogWritable else { return }
        guard writable else { reportMigrationFailure(); return }
        var next = catalogState
        var routes = savedRoutes
        let hadRoutingFile = routingStore.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if calendarConfigured || detectsHalfDays || hasLegacyAttendance || hadRoutingFile {
            next.installed["mac-calendar"] = true
            // Before the catalog existed, builtin and absent routes meant Mac Calendar.
            for feature in [AppFeature.calendar, .halfDay] where routes[feature] == nil || routes[feature] == router.defaultID {
                routes[feature] = "mac-calendar"
            }
        }
        if daouConfigured { next.installed["daouoffice"] = true }
        if detectsHalfDays { next.installed["leave-detection"] = true }
        var originalRoutes: Data?
        var attemptedRouteWrite = false
        do {
            if hadRoutingFile, let url = routingStore.url { originalRoutes = try Data(contentsOf: url) }
            if routes != savedRoutes {
                attemptedRouteWrite = true
                try routingStore.save(routes)
            }
            try catalogStore.save(next)
            savedRoutes = routes; catalogState = next; hasCatalogState = true
        } catch {
            catalogWritable = false
            message = "플러그인 이관을 저장하지 못했습니다. 기존 파일을 보존했습니다."
            if attemptedRouteWrite, let url = routingStore.url {
                do {
                    if let originalRoutes {
                        if (try? Data(contentsOf: url)) != originalRoutes { try originalRoutes.write(to: url, options: .atomic) }
                    }
                    else if !hadRoutingFile, FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                } catch {
                    message = "플러그인 이관과 기능 연결 복구에 실패했습니다. 파일 접근 권한을 확인한 뒤 다시 실행해 주세요."
                }
            }
            return
        }
        for entry in installed where !registrations.contains(where: { $0.id == entry.id }) { activateInstalled(entry.id) }
        revision += 1
    }
    func install(_ id: String) {
        guard catalogWritable, !isInstalled(id), catalog.first(where: { $0.id == id })?.available == true else { return }
        var next = catalogState; next.installed[id] = false
        do { try catalogStore.save(next); catalogState = next; hasCatalogState = true; activateInstalled(id) }
        catch { message = "플러그인 설치 상태를 저장하지 못했습니다." }
        revision += 1
    }
    func setEnabled(_ id: String, _ value: Bool) {
        guard catalogWritable, isInstalled(id) else { return }
        let entry = registrations.first(where: { $0.id == id })
        if value, entry == nil || catalog.first(where: { $0.id == id })?.available != true {
            message = "이 빌드에서는 해당 플러그인을 사용할 수 없습니다."
            return
        }
        var next = catalogState; next.installed[id] = value
        do {
            try catalogStore.save(next); catalogState = next
            if id == "leave-detection" { leaveDetectionGeneration += 1 }
            if value {
                entry?.setEnabled?(true)
                if started && externalIntegrationsAllowed { entry?.controller.start() }
                router.setEnabled(entry?.controller.enabled == true && externalIntegrationsAllowed, for: id)
                if id == "mac-calendar", externalIntegrationsAllowed {
                    for feature in [AppFeature.calendar, .halfDay] where router.selectedID(for: feature) == router.defaultID
                        && savedRoutes[feature] == nil {
                        try? router.select(id, for: feature)
                    }
                }
                for (feature, source) in savedRoutes where source == id { try? router.select(id, for: feature) }
            } else {
                entry?.controller.stop(); entry?.setEnabled?(false); router.setEnabled(false, for: id)
            }
            persistRoutes(); revision += 1
        } catch { message = "플러그인 사용 상태를 저장하지 못했습니다." }
    }
    private func activateInstalled(_ id: String) {
        guard let factory = factories[id] else { return }
        do {
            if !registrations.contains(where: { $0.id == id }) { try factory() }
            guard let entry = registrations.first(where: { $0.id == id }) else { return }
            let active = isEnabled(id) && externalIntegrationsAllowed
            entry.setEnabled?(active)
            if !active { entry.controller.stop() }
            router.setEnabled(active && entry.controller.enabled, for: id)
            if active {
                for (feature, source) in savedRoutes where source == id { try? router.select(id, for: feature) }
            }
            if active, id == "mac-calendar" {
                for feature in [AppFeature.calendar, .halfDay] where savedRoutes[feature] == nil {
                    try? router.select(id, for: feature)
                }
            }
        } catch { reportRegistrationFailure() }
    }
    func register(_ registration: PluginRegistration) throws {
        guard registration.id == registration.adapter.descriptor.id,
              !registrations.contains(where: { $0.id == registration.id }) else { throw PluginFailure.duplicatePlugin }
        try router.register(registration.adapter, enabled: registration.controller.enabled)
        registrations.append(registration)
        subscriptions[registration.id] = registration.controller.changes.sink { [weak self] in
            // ObservableObject emits before its @Published values change.
            Task { @MainActor [weak self] in self?.synchronize() }
        }
        for (feature, id) in savedRoutes where id == registration.id {
            try? router.select(id, for: feature)
        }
        if started && (!catalogConfigured || (isEnabled(registration.id) && externalIntegrationsAllowed)) { registration.controller.start() }
        revision += 1
    }
    func unregister(_ id: String) {
        removeRegistration(id, saveRoutes: true)
    }
    func rollbackRegistration(_ id: String) {
        removeRegistration(id, saveRoutes: false)
    }
    private func removeRegistration(_ id: String, saveRoutes: Bool) {
        guard let entry = registrations.first(where: { $0.id == id }) else { return }
        entry.controller.stop(); registry.unregister(id); router.unregister(id)
        subscriptions[id] = nil; registrations.removeAll { $0.id == id }
        if saveRoutes {
            savedRoutes = savedRoutes.filter { $0.value != id }
            persistRoutes()
        }
        revision += 1
    }
    func start() {
        guard !started else { return }; started = true
        registrations.filter { !catalogConfigured || (isEnabled($0.id) && externalIntegrationsAllowed) }.forEach { $0.controller.start() }
    }
    func reportMigrationFailure() {
        catalogWritable = false
        message = "기존 플러그인 설정을 읽지 못했습니다. 원본을 보존하고 플러그인 상태 변경을 중지했습니다."
    }
    func reportRegistrationFailure() {
        message = "플러그인을 등록하지 못했습니다. 기본 기능은 계속 사용할 수 있습니다."
    }
    func stop() { registrations.forEach { $0.controller.stop() }; started = false }
    var isRunning: Bool { registrations.contains { $0.controller.isRunning } }
    var canChangeRoutes: Bool { writable && (!catalogConfigured || catalogWritable) }
    var leaveSnapshot: PluginSnapshot? { router.leaveSnapshot() }
    func refreshSource(for feature: AppFeature) {
        let id = router.selectedID(for: feature)
        if let entry = registrations.first(where: { $0.id == id }), entry.controller.enabled, !entry.controller.isRunning {
            entry.controller.refreshData()
        }
        revision += 1
    }
    func select(_ id: String, for feature: AppFeature) {
        guard canChangeRoutes else { return }
        let old = router.selectedID(for: feature)
        do {
            try router.select(id, for: feature)
            var desired = savedRoutes
            desired[feature] = id
            try routingStore.save(desired)
            savedRoutes = desired; message = nil
        } catch {
            try? router.select(old, for: feature)
            message = "기능 연결을 저장하지 못했습니다. 연결 상태와 설정 파일 접근 권한을 확인해 주세요."
        }
        revision += 1
    }
    private func synchronize() {
        let before = router.revision
        for entry in registrations {
            router.setEnabled(entry.controller.enabled && (!catalogConfigured || (isEnabled(entry.id) && externalIntegrationsAllowed)), for: entry.id)
        }
        for (feature, source) in savedRoutes where router.isEnabled(source) {
            try? router.select(source, for: feature)
        }
        if before != router.revision { persistRoutes() }
        revision += 1
    }
    private func persistRoutes() {
        guard canChangeRoutes else { return }
        do {
            // Runtime fallback is transient; only an explicit selection forgets a route.
            var desired = savedRoutes
            for (feature, source) in router.selection where desired[feature] == nil { desired[feature] = source }
            try routingStore.save(desired); savedRoutes = desired
        }
        catch { message = "기능 연결을 저장하지 못했습니다. 이번 실행에서는 기본 연결로 돌아갑니다." }
    }
    func adapterName(_ id: String) -> String {
        id == router.defaultID ? L("happylulu 기본", "happylulu default")
            : registrations.first { $0.id == id }?.controller.descriptor.name ?? id
    }
}
