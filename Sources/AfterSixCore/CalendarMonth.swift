import Foundation

public struct CalendarMonth: Sendable {
    public let calendar: Calendar
    public let start: Date
    public let end: Date
    public let days: [Date?]

    public init(containing date: Date, calendar: Calendar) {
        self.calendar = calendar
        let interval = calendar.dateInterval(of: .month, for: date)!
        start = interval.start
        end = interval.end
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        var cells = [Date?](repeating: nil, count: offset)
        var day = start
        while day < end {
            cells.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        cells.append(contentsOf: repeatElement(nil, count: (7 - cells.count % 7) % 7))
        days = cells
    }

    public func shifted(by months: Int) -> CalendarMonth {
        CalendarMonth(containing: calendar.date(byAdding: .month, value: months, to: start)!, calendar: calendar)
    }

    /// Calendar day boundaries preserve DST; an event ending at midnight belongs to the preceding day.
    public func overlaps(day: Date, start eventStart: Date, end eventEnd: Date) -> Bool {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        if eventStart == eventEnd { return eventStart >= start && eventStart < end }
        return eventStart < end && eventEnd > start && eventEnd > eventStart
    }
}
