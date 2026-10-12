import Foundation
import AfterSixCore

func checkEarlyArrival() throws {
    let t = AttendanceTests()
    for isLogin in [false, true] {
        for (time, expected) in [("05:59:59", nil), ("06:00:00", "08:00:00"),
                                 ("07:59:59", "08:00:00"), ("08:00:00", "08:00:00"),
                                 ("08:47:12", "08:47:12"), ("10:00:59", "10:00:59"),
                                 ("10:01:00", nil)] as [(String, String?)] {
            let event = t.date("2026-10-23T" + time)
            var state = AttendanceState()
            let recorded = isLogin
                ? Attendance.recordLogin(in: &state, at: event, calendar: t.calendar)
                : Attendance.recordUnlock(in: &state, at: event, calendar: t.calendar)
            expectEqual(recorded, expected != nil)
            expectEqual(state.lastUnlockAt, isLogin ? nil : event)
            if let expected {
                let at = t.date("2026-10-23T" + expected)
                let arrival = state.arrivals["2026-10-23"]!
                expectEqual(arrival.time, at)
                expectEqual(arrival.source, isLogin ? .login : .unlock)
                expectEqual(arrival.mode, .normal)
                expectEqual(Attendance.departure(for: arrival, settings: state.settings), at.addingTimeInterval(9 * 3600))
                expectEqual(Attendance.progress(from: at, until: at.addingTimeInterval(9 * 3600), now: event), 0)
            } else {
                expectTrue(state.arrivals.isEmpty)
            }
        }
    }
    for mode in [WorkdayMode.normal, .afternoonHalf, .morningHalf] {
        var state = AttendanceState()
        let event = t.date("2026-10-23T06:00:00")
        expectEqual(Attendance.recordUnlock(in: &state, at: event, calendar: t.calendar,
                                           calendarMode: mode), mode != .morningHalf)
        if mode != .morningHalf {
            let arrival = state.arrivals["2026-10-23"]!
            expectEqual(arrival.time, t.date("2026-10-23T08:00:00"))
            expectEqual(arrival.mode, mode)
            expectEqual(Attendance.departure(for: arrival, settings: state.settings),
                        t.date(mode == .normal ? "2026-10-23T17:00:00" : "2026-10-23T12:00:00"))
        } else {
            expectTrue(Attendance.recordUnlock(in: &state, at: t.date("2026-10-23T13:00:00"),
                                              calendar: t.calendar, calendarMode: mode))
        }
    }
    var state = AttendanceState()
    let early = t.date("2026-10-23T06:00:00")
    expectTrue(Attendance.recordLogin(in: &state, at: early, calendar: t.calendar))
    let first = state.arrivals
    for time in ["07:59:59", "08:00:00", "09:00:00", "13:00:00"] {
        let later = t.date("2026-10-23T" + time)
        expectFalse(Attendance.recordUnlock(in: &state, at: later, calendar: t.calendar))
        expectFalse(Attendance.recordLogin(in: &state, at: later, calendar: t.calendar))
        expectEqual(state.arrivals, first)
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = StateStore(url: folder.appendingPathComponent("state.json"))
    try store.save(state)
    try expectEqual(store.load(), state)
    Attendance.skipToday(in: &state, now: early, calendar: t.calendar)
    expectFalse(Attendance.recordUnlock(in: &state, at: early, calendar: t.calendar))
    expectFalse(Attendance.recordLogin(in: &state, at: early, calendar: t.calendar))
    expectTrue(state.arrivals.isEmpty)
    for mode in [WorkdayMode.normal, .afternoonHalf, .morningHalf] {
        var manual = AttendanceState()
        expectThrows(try Attendance.setManual(in: &manual, at: t.date("2026-10-23T07:00:00"),
                                              now: t.date("2026-10-23T09:00:00"), calendar: t.calendar,
                                              selectedMode: mode))
        expectEqual(manual, AttendanceState())
    }
    var manual = AttendanceState()
    try Attendance.setManual(in: &manual, at: t.date("2026-10-23T08:30:00"),
                             now: t.date("2026-10-23T09:00:00"), calendar: t.calendar)
    let savedManual = manual.arrivals
    expectFalse(Attendance.recordUnlock(in: &manual, at: early, calendar: t.calendar))
    expectEqual(manual.arrivals, savedManual)
    var dstCalendar = Calendar(identifier: .gregorian)
    dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let format = ISO8601DateFormatter()
    for day in ["2026-03-08", "2026-11-01"] {
        let offset = day.hasSuffix("03-08") ? "-07:00" : "-08:00"
        let event = format.date(from: day + "T06:00:00" + offset)!
        var dst = AttendanceState()
        expectTrue(Attendance.recordUnlock(in: &dst, at: event, calendar: dstCalendar))
        expectEqual(dst.arrivals[day]?.time, format.date(from: day + "T08:00:00" + offset))
    }
    print("PASS early arrival: login/unlock boundaries, normalized departure, half days, first-event protection, manual/day-off preservation, persistence and local DST")
}
