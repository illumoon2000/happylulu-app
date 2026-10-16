import Foundation
import Combine
import AppPluginCore

public enum PluginConnectionState: Equatable { case off, setup, connecting, ready, attention }

/// A plugin owns its settings and lifecycle; the catalog never understands its wire API.
@MainActor
public protocol PluginController: AnyObject {
    var descriptor: PluginDescriptor { get }
    var changes: AnyPublisher<Void, Never> { get }
    var enabled: Bool { get }
    var isRunning: Bool { get }
    var connectionState: PluginConnectionState { get }
    func start()
    func stop()
    func refreshData()
}

public struct PluginRegistration: Identifiable {
    public let id: String
    public let controller: any PluginController
    public let adapter: any FeatureAdapter
    public let symbol: String
    public let setEnabled: (@MainActor (Bool) -> Void)?
    public let summaryKorean: String
    public let summaryEnglish: String
    @MainActor
    public init(controller: any PluginController, adapter: any FeatureAdapter, symbol: String, summary: String,
         englishSummary: String? = nil, setEnabled: (@MainActor (Bool) -> Void)? = nil) {
        id = controller.descriptor.id; self.controller = controller; self.adapter = adapter
        self.setEnabled = setEnabled
        self.symbol = symbol; self.summaryKorean = summary; self.summaryEnglish = englishSummary ?? summary
    }
}

public typealias PluginLocalizer = @MainActor (String, String) -> String

@MainActor
public struct PluginHostContext {
    public let registry: PluginRegistry
    public let presentations: PluginSettingsPresentationRegistry
    public let register: @MainActor (PluginRegistration) throws -> Void
    public let localize: PluginLocalizer
    private let rollback: @MainActor (String) -> Void
    public init(registry: PluginRegistry, presentations: PluginSettingsPresentationRegistry,
                register: @escaping @MainActor (PluginRegistration) throws -> Void,
                rollback: @escaping @MainActor (String) -> Void, localize: @escaping PluginLocalizer) {
        self.registry = registry; self.presentations = presentations
        self.register = register; self.rollback = rollback; self.localize = localize
    }

    /// One module owns one ID. Failed installation removes only its new registrations.
    public func install(_ module: any PluginModule.Type) throws {
        let id = module.id
        guard !registry.descriptors.contains(where: { $0.id == id }), !presentations.contains(id) else {
            throw PluginFailure.duplicatePlugin
        }
        var registered = false
        let scoped = PluginHostContext(registry: registry, presentations: presentations, register: { registration in
            guard registration.id == id, !registered else { throw PluginFailure.configuration }
            try register(registration)
            registered = true
        }, rollback: rollback, localize: localize)
        do {
            try module.register(in: scoped)
            guard registered else { throw PluginFailure.configuration }
        } catch {
            if registered { rollback(id) }
            if registry.descriptors.contains(where: { $0.id == id }) { registry.unregister(id) }
            presentations.unregister(id)
            throw error
        }
    }
}

@MainActor
public protocol PluginModule {
    static var id: String { get }
    static func register(in context: PluginHostContext) throws
}
