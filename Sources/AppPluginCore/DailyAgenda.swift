import Foundation

/// A bounded summary of one local civil day; full calendars keep their existing source data.
public struct DailyAgenda: Sendable {
    public let items: [FeatureCalendarEvent]
    public let remainingCount: Int

    public init(events: [FeatureCalendarEvent], on day: Date, calendar: Calendar) {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let today = events.filter {
            $0.start < end && ($0.end > start || ($0.start == $0.end && $0.start >= start))
        }.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
        items = Array(today.prefix(3))
        remainingCount = max(0, today.count - items.count)
    }
}
