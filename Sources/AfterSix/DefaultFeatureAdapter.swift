import Foundation
import Combine
import AppPluginCore
import AppPluginHost

/// Core attendance never touches optional services.
@MainActor
final class DefaultFeatureAdapter: FeatureAdapter {
    let descriptor = FeatureAdapterDescriptor(id: "builtin", name: "HappyLulu", features: Set(AppFeature.allCases))
    init(sync: CalendarSyncModel? = nil) {}
    func calendarEvents(in interval: DateInterval) async throws -> [FeatureCalendarEvent] { [] }
    func leaveSnapshot() -> PluginSnapshot? { nil }
    func requestHalfDayAccess() async throws { throw FeatureAdapterFailure.unavailable }
    func halfDayTitles(on day: Date, timeZone: TimeZone) async throws -> [String] { [] }
}

@MainActor
final class MacCalendarFeatureAdapter: FeatureAdapter {
    let descriptor = FeatureAdapterDescriptor(id: "mac-calendar", name: "Mac Calendar", features: [.calendar, .halfDay])
    private let sync: CalendarSyncModel
    private lazy var halfDays = HalfDayCalendarReader()
    init(sync: CalendarSyncModel) { self.sync = sync }
    func calendarEvents(in interval: DateInterval) async throws -> [FeatureCalendarEvent] {
        try await sync.featureEvents(in: interval).map {
            FeatureCalendarEvent(sourceID: descriptor.id, eventID: $0.id, calendarID: $0.calendarID,
                title: $0.title, start: $0.start, end: $0.end, isAllDay: $0.isAllDay, location: $0.location)
        }
    }
    func leaveSnapshot() -> PluginSnapshot? { nil }
    func requestHalfDayAccess() async throws { try await halfDays.requestAccess() }
    func halfDayTitles(on day: Date, timeZone: TimeZone) async throws -> [String] {
        try await halfDays.titles(on: day, timeZone: timeZone)
    }
}

@MainActor
final class LocalPluginController: ObservableObject, PluginController {
    let descriptor: PluginDescriptor
    @Published private(set) var enabled = false
    private let onChange: (Bool) -> Void
    var changes: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
    var isRunning: Bool { false }
    var connectionState: PluginConnectionState { enabled ? .ready : .off }
    init(id: String, name: String, onChange: @escaping (Bool) -> Void = { _ in }) {
        descriptor = PluginDescriptor(id: id, name: name); self.onChange = onChange
    }
    func setEnabled(_ value: Bool) { enabled = value; onChange(value) }
    func start() { onChange(enabled) }
    func stop() { onChange(false) }
    func refreshData() {}
}

@MainActor
final class LeaveDetectionFeatureAdapter: FeatureAdapter {
    let descriptor = FeatureAdapterDescriptor(id: "leave-detection", name: "Leave recognition", features: [])
    func calendarEvents(in interval: DateInterval) async throws -> [FeatureCalendarEvent] { [] }
    func leaveSnapshot() -> PluginSnapshot? { nil }
    func requestHalfDayAccess() async throws { throw FeatureAdapterFailure.unsupported }
    func halfDayTitles(on day: Date, timeZone: TimeZone) async throws -> [String] { [] }
}
