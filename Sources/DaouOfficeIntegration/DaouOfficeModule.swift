import Foundation
import AppPluginCore
import AppPluginHost
import DaouOfficePlugin

public enum DaouOfficeModule: PluginModule {
    public static let id = "daouoffice"
    public static func hasLegacyConfiguration() throws -> Bool {
        try DaouOfficeConfigurationStore().load() != nil
    }
    @MainActor
    public static func register(in context: PluginHostContext) throws {
        let controller = DaouOfficePluginModel(registry: context.registry, loadSavedPasswordAtInitialization: false, localize: context.localize)
        let adapter = SnapshotFeatureAdapter(descriptor: FeatureAdapterDescriptor(
            id: id, name: "Daouoffice", features: Set(AppFeature.allCases)),
            api: context.registry, timeZone: TimeZone(identifier: "Asia/Seoul")!, inclusiveAllDayEnd: true)
        try context.register(PluginRegistration(controller: controller, adapter: adapter,
            symbol: "building.2", summary: "회사 휴가 · 캘린더 일정", englishSummary: "Company leave · calendar events", setEnabled: controller.setModuleEnabled))
        let localize = context.localize
        try context.presentations.register(id) {
            DaouOfficePluginSettingsView(model: controller, localize: localize)
        }
    }
}
