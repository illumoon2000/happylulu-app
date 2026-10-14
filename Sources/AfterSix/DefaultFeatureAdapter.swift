import Foundation
import AppPluginCore

@MainActor
final class DefaultFeatureAdapter: FeatureAdapter {
    let descriptor = FeatureAdapterDescriptor(id: "builtin", name: "HappyLulu",
        features: Set(AppFeature.allCases))
    private let sync: CalendarSyncModel
    private let halfDays = HalfDayCalendarReader()
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
