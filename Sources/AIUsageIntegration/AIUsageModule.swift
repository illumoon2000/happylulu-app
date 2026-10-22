import Foundation
import AppPluginCore
import AppPluginHost

public enum AIUsageModule: PluginModule {
    public static let id = "ai-usage"
    public static var catalogMetadata: PluginModuleMetadata? {
        PluginModuleMetadata(name: "AI 사용량", englishName: "AI Usage", author: "HappyLulu contributors",
            summary: "Codex 주간 잔여량 · 시간당 소모율", englishSummary: "Codex weekly allowance · hourly consumption",
            symbol: "gauge.with.dots.needle.50percent", providesUsage: true)
    }
    @MainActor public static func register(in context: PluginHostContext) throws {
        let model = AIUsageModel(localize: context.localize)
        // Usage data has no calendar/leave capability and never replaces those feature routes.
        let adapter = SnapshotFeatureAdapter(descriptor: FeatureAdapterDescriptor(id: id, name: "AI Usage", features: []),
            api: context.registry, timeZone: .current)
        try context.register(PluginRegistration(controller: model, adapter: adapter,
            symbol: "gauge.with.dots.needle.50percent", summary: "Codex 주간 잔여량 · 시간당 소모율",
            englishSummary: "Codex weekly allowance · hourly consumption", setEnabled: model.setEnabled))
        try context.presentations.register(id) { AIUsageSettingsView(model: model) }
    }
}
