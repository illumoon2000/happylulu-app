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

@MainActor
final class PluginManagerModel: ObservableObject {
    let registry: PluginRegistry
    let router: FeatureAdapterRouter
    @Published private(set) var registrations: [PluginRegistration] = []
    @Published private(set) var revision = 0
    @Published private(set) var message: String?
    private let routingStore: FeatureRoutingStore
    private var subscriptions: [String: AnyCancellable] = [:]
    private var started = false
    private var savedRoutes: [AppFeature: String] = [:]
    private var writable = true

    init(defaultAdapter: any FeatureAdapter, registry: PluginRegistry = PluginRegistry(),
         routingStore: FeatureRoutingStore = .standard) {
        self.registry = registry; self.router = FeatureAdapterRouter(defaultAdapter: defaultAdapter)
        self.routingStore = routingStore
        do { savedRoutes = try routingStore.load() }
        catch { writable = false; message = "기능 연결 설정을 읽지 못했습니다. 원본을 보존하고 기본 연결을 사용합니다." }
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
        if started { registration.controller.start() }
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
        if saveRoutes { persistRoutes() }
        revision += 1
    }
    func start() {
        guard !started else { return }; started = true
        registrations.forEach { $0.controller.start() }
    }
    func reportRegistrationFailure() {
        message = "플러그인을 등록하지 못했습니다. 기본 기능은 계속 사용할 수 있습니다."
    }
    func stop() { registrations.forEach { $0.controller.stop() }; started = false }
    var isRunning: Bool { registrations.contains { $0.controller.isRunning } }
    var canChangeRoutes: Bool { writable }
    var leaveSnapshot: PluginSnapshot? { router.leaveSnapshot() }
    func refreshSource(for feature: AppFeature) {
        let id = router.selectedID(for: feature)
        if let entry = registrations.first(where: { $0.id == id }), entry.controller.enabled, !entry.controller.isRunning {
            entry.controller.refreshData()
        }
        revision += 1
    }
    func select(_ id: String, for feature: AppFeature) {
        guard writable else { return }
        let old = router.selectedID(for: feature)
        do {
            try router.select(id, for: feature)
            try routingStore.save(router.selection)
            savedRoutes = router.selection; message = nil
        } catch {
            try? router.select(old, for: feature)
            message = "기능 연결을 저장하지 못했습니다. 연결 상태와 설정 파일 접근 권한을 확인해 주세요."
        }
        revision += 1
    }
    private func synchronize() {
        let before = router.revision
        for entry in registrations { router.setEnabled(entry.controller.enabled, for: entry.id) }
        if before != router.revision { persistRoutes() }
        revision += 1
    }
    private func persistRoutes() {
        guard writable else { return }
        do { try routingStore.save(router.selection); savedRoutes = router.selection }
        catch { message = "기능 연결을 저장하지 못했습니다. 이번 실행에서는 기본 연결로 돌아갑니다." }
    }
    func adapterName(_ id: String) -> String {
        id == router.defaultID ? L("HappyLulu 기본", "HappyLulu default")
            : registrations.first { $0.id == id }?.controller.descriptor.name ?? id
    }
}
