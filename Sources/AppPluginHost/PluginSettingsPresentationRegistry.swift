import SwiftUI
import AppPluginCore

/// Presentation registration stays separate from plugin lifecycle and data processing.
@MainActor
public final class PluginSettingsPresentationRegistry {
    public init() {}
    private var factories: [String: () -> AnyView] = [:]
    public func register<V: View>(_ id: String, @ViewBuilder content: @escaping () -> V) throws {
        guard factories[id] == nil else { throw PluginFailure.duplicatePlugin }
        factories[id] = { AnyView(content()) }
    }
    public func contains(_ id: String) -> Bool { factories[id] != nil }
    public func view(for id: String) -> AnyView? { factories[id]?() }
    public func unregister(_ id: String) { factories[id] = nil }
}
