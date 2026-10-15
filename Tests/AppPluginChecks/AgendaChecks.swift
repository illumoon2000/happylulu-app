import Foundation
import AppPluginCore

func checkDailyAgenda() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let day = ISO8601DateFormatter().date(from: "2026-03-08T12:00:00-04:00")!
    let start = calendar.startOfDay(for: day)
    let end = calendar.date(byAdding: .day, value: 1, to: start)!
    require(end.timeIntervalSince(start) == 23 * 3600, "Fixture must cover a DST day")
    func event(_ id: String, _ begin: Date, _ finish: Date, allDay: Bool = false) -> FeatureCalendarEvent {
        FeatureCalendarEvent(sourceID: "fixture", eventID: id, calendarID: "test", title: id,
                             start: begin, end: finish, isAllDay: allDay, location: nil)
    }
    let a = event("a", start.addingTimeInterval(3600), start.addingTimeInterval(7200))
    let b = event("b", start.addingTimeInterval(7200), start.addingTimeInterval(10800))
    let c = event("c", start.addingTimeInterval(10800), start.addingTimeInterval(14400))
    let zero = event("zero", start.addingTimeInterval(18000), start.addingTimeInterval(18000))
    let allDay = event("all-day", start, end, allDay: true)
    let previous = event("previous", start.addingTimeInterval(-3600), start)
    let next = event("next", end, end.addingTimeInterval(3600))
    let spanning = event("spanning", start.addingTimeInterval(-3600), end.addingTimeInterval(3600))
    let agenda = DailyAgenda(events: [c, next, b, previous, zero, a, allDay, spanning], on: day, calendar: calendar)
    require(agenda.items.map(\.title) == ["all-day", "spanning", "a"], "Today order and overlap must be deterministic")
    require(agenda.remainingCount == 3, "Only three rows fit; remaining count must match today")
    require(DailyAgenda(events: [], on: day, calendar: calendar).items.isEmpty, "Empty agenda must remain empty")
    let exact = DailyAgenda(events: [c,b,a], on: day, calendar: calendar)
    require(exact.items.map(\.title) == ["a","b","c"] && exact.remainingCount == 0, "Three events must fit exactly")
    print("PASS compact daily agenda: three-row limit, remaining count, empty, order, all-day, spanning, exact midnight and DST")
}
