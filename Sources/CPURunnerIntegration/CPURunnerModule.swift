import Foundation
import AppPluginCore
import AppPluginHost

public enum CPURunnerModule: PluginModule {
    public static let id = "cpu-runner"

    @MainActor
    public static func register(in context: PluginHostContext) throws {
        let controller = CPURunnerController(localize: context.localize)
        try context.register(PluginRegistration(controller: controller, adapter: RunnerFeatureAdapter(),
            symbol: "pawprint", summary: "CPU 사용량에 따라 움직이는 햄스터 · 토끼 · 고양이",
            englishSummary: "A hamster, rabbit or cat that moves with CPU usage", setEnabled: controller.setModuleEnabled))
        let localize = context.localize
        try context.presentations.register(id) { CPURunnerSettingsView(model: controller, localize: localize) }
    }
}

@MainActor
private final class RunnerFeatureAdapter: FeatureAdapter {
    let descriptor = FeatureAdapterDescriptor(id: CPURunnerModule.id, name: "CPU Runner", features: [])
    func calendarEvents(in interval: DateInterval) async throws -> [FeatureCalendarEvent] { [] }
    func leaveSnapshot() -> PluginSnapshot? { nil }
    func requestHalfDayAccess() async throws { throw FeatureAdapterFailure.unsupported }
    func halfDayTitles(on day: Date, timeZone: TimeZone) async throws -> [String] { [] }
}
