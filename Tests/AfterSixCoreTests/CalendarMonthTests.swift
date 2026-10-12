import Foundation
import AfterSixCore

func checkCalendarMonth() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    calendar.firstWeekday = 1
    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
    let leap = CalendarMonth(containing: date(2024, 2, 15), calendar: calendar)
    expectEqual(leap.days.compactMap { $0 }.count, 29)
    expectEqual(leap.days.prefix(4).compactMap { $0 }.count, 0)
    expectEqual(leap.days.count, 35)
    expectEqual(leap.end, date(2024, 3, 1))
    let sixWeeks = CalendarMonth(containing: date(2026, 8, 15), calendar: calendar)
    expectEqual(sixWeeks.days.count, 42)
    expectEqual(sixWeeks.days.compactMap { $0 }.first, date(2026, 8, 1))
    let next = CalendarMonth(containing: date(2026, 12, 1), calendar: calendar).shifted(by: 1)
    expectEqual(next.start, date(2027, 1, 1))
    calendar.firstWeekday = 2
    expectEqual(CalendarMonth(containing: date(2026, 6, 1), calendar: calendar).days.first!, date(2026, 6, 1))

    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let spring = CalendarMonth(containing: date(2026, 3, 8), calendar: calendar)
    let day = date(2026, 3, 8), following = date(2026, 3, 9)
    expectEqual(following.timeIntervalSince(day), 23 * 3600)
    expectFalse(spring.overlaps(day: day, start: date(2026, 3, 7), end: day))
    expectTrue(spring.overlaps(day: day, start: day, end: following))
    expectFalse(spring.overlaps(day: following, start: day, end: following))
    expectTrue(spring.overlaps(day: day, start: day, end: day))
    expectFalse(spring.overlaps(day: following, start: day, end: day))

    let instant = ISO8601DateFormatter().date(from: "2026-10-12T00:30:00+09:00")!
    let buddhistRecord = Arrival(day: "2569-10-12", time: instant, source: .unlock, timeZoneID: "Asia/Seoul")
    expectEqual(Attendance.historyDay(for: buddhistRecord), "2026-10-12")
    let travelingRecord = Arrival(day: "2026-10-11", time: instant, source: .manual, timeZoneID: "America/New_York")
    expectEqual(Attendance.historyDay(for: travelingRecord), "2026-10-11")
    expectEqual(buddhistRecord.day, "2569-10-12")
}
