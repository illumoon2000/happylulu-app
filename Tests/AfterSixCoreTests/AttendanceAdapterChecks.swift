import Foundation
import AfterSixCore

func checkAttendanceAdapter() throws {
    let adapter = DefaultAttendanceAdapter()
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    let formatter = ISO8601DateFormatter()
    let date = formatter.date(from: "2026-10-13T09:00:00+09:00")!
    var legacy = AttendanceState(), adapted = AttendanceState()
    Attendance.recordLogin(in: &legacy, at: date, calendar: calendar, calendarMode: .afternoonHalf)
    _ = try adapter.apply(.login(at: date, mode: .afternoonHalf), to: &adapted, calendar: calendar)
    expectEqual(adapted, legacy)
    let later = date.addingTimeInterval(60)
    Attendance.recordUnlock(in: &legacy, at: later, calendar: calendar, calendarMode: .morningHalf)
    _ = try adapter.apply(.unlock(at: later, mode: .morningHalf), to: &adapted, calendar: calendar)
    expectEqual(adapted, legacy)
    try Attendance.setManual(in: &legacy, at: date, now: later, calendar: calendar, selectedMode: .normal, calendarMode: .afternoonHalf)
    _ = try adapter.apply(.manual(at: date, now: later, selectedMode: .normal, calendarMode: .afternoonHalf), to: &adapted, calendar: calendar)
    _ = Attendance.refreshAutomaticMode(in: &legacy, now: later, calendar: calendar, calendarMode: .afternoonHalf)
    _ = try adapter.apply(.refreshMode(now: later, mode: .afternoonHalf), to: &adapted, calendar: calendar)
    expectEqual(adapted, legacy)
    let arrival = adapter.today(in: adapted, now: later, calendar: calendar)!
    expectEqual(adapter.departure(for: arrival, settings: adapted.settings), Attendance.departure(for: arrival, settings: legacy.settings))
    let original = adapted
    expectThrows(try adapter.apply(.settings(work: -1, rest: 60), to: &adapted, calendar: calendar))
    expectEqual(adapted, original)
    Attendance.skipToday(in: &legacy, now: later, calendar: calendar)
    _ = try adapter.apply(.skip(now: later), to: &adapted, calendar: calendar)
    expectEqual(adapted, legacy)
    print("PASS default attendance adapter: login/unlock/manual/half-day/skip parity, existing state and failed settings preservation")
}
