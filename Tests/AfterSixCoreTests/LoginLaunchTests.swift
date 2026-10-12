import AppKit
import AfterSixCore
import MacLaunchSupport

func checkLoginLaunch() throws {
    func event(_ id: AEEventID = AEEventID(kAEOpenApplication),
               kind: OSType? = nil, eventClass: AEEventClass = AEEventClass(kCoreEventClass)) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor(eventClass: eventClass, eventID: id,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let kind { descriptor.setParam(NSAppleEventDescriptor(enumCode: kind), forKeyword: AEKeyword(keyAEPropData)) }
        return descriptor
    }
    expectFalse(LoginLaunch.isLoginItem(nil))
    expectFalse(LoginLaunch.isLoginItem(event()))
    expectFalse(LoginLaunch.isLoginItem(event(kind: 0)))
    expectFalse(LoginLaunch.isLoginItem(event(kind: OSType(keyAELaunchedAsServiceItem))))
    expectFalse(LoginLaunch.isLoginItem(event(AEEventID(kAEReopenApplication), kind: OSType(keyAELaunchedAsLogInItem))))
    expectFalse(LoginLaunch.isLoginItem(event(kind: OSType(keyAELaunchedAsLogInItem), eventClass: 0)))
    expectTrue(LoginLaunch.isLoginItem(event(kind: OSType(keyAELaunchedAsLogInItem))))
    print("PASS login Apple event: login only, nil/manual/service/reopen/wrong class rejected")

    let t = AttendanceTests()
    let first = t.date("2026-10-07T08:47:12")
    let later = first.addingTimeInterval(60)
    var state = AttendanceState()
    expectTrue(Attendance.recordLogin(in: &state, at: first, calendar: t.calendar))
    expectNil(state.lastUnlockAt)
    expectEqual(state.arrivals["2026-10-07"]?.source, .login)
    expectFalse(Attendance.recordUnlock(in: &state, at: later, calendar: t.calendar))
    expectFalse(Attendance.recordLogin(in: &state, at: later, calendar: t.calendar))
    expectEqual(state.arrivals["2026-10-07"]?.time, first)
    expectEqual(state.lastUnlockAt, later)
    let encoded = try JSONEncoder().encode(state)
    try expectEqual(try JSONDecoder().decode(AttendanceState.self, from: encoded), state)
    try Attendance.setManual(in: &state, at: first.addingTimeInterval(-60), now: later, calendar: t.calendar)
    let manual = state
    expectFalse(Attendance.recordLogin(in: &state, at: later, calendar: t.calendar))
    expectEqual(state, manual)
    Attendance.skipToday(in: &state, now: first, calendar: t.calendar)
    let skipped = state
    expectFalse(Attendance.recordLogin(in: &state, at: later, calendar: t.calendar))
    expectEqual(state, skipped)
    expectTrue(Attendance.recordLogin(in: &state, at: t.date("2026-10-08T09:00:00"), calendar: t.calendar))
    print("PASS login arrival: observed time/source, duplicate/unlock/manual/day-off preservation, next day, Codable round trip")

    for (time, allowed) in [("05:59:59", false), ("06:00:00", true), ("07:59:59", true), ("08:00:00", true), ("10:00:59", true),
                            ("10:01:00", false), ("12:59:59", false), ("13:00:00", true),
                            ("15:00:59", true), ("15:01:00", false)] {
        var state = AttendanceState()
        expectEqual(Attendance.recordLogin(in: &state, at: t.date("2026-10-07T" + time), calendar: t.calendar), allowed)
        expectNil(state.lastUnlockAt)
    }
    var morning = AttendanceState()
    expectFalse(Attendance.recordLogin(in: &morning, at: first, calendar: t.calendar, calendarMode: .morningHalf))
    expectTrue(Attendance.recordLogin(in: &morning, at: t.date("2026-10-07T13:30:00"), calendar: t.calendar, calendarMode: .morningHalf))
    expectEqual(morning.arrivals["2026-10-07"]?.mode, .morningHalf)
    var afternoon = AttendanceState()
    expectTrue(Attendance.recordLogin(in: &afternoon, at: first, calendar: t.calendar, calendarMode: .afternoonHalf))
    expectEqual(afternoon.arrivals["2026-10-07"]?.mode, .afternoonHalf)
    var unlockFirst = AttendanceState()
    Attendance.recordUnlock(in: &unlockFirst, at: first, calendar: t.calendar)
    let original = unlockFirst
    expectFalse(Attendance.recordLogin(in: &unlockFirst, at: later, calendar: t.calendar))
    expectEqual(unlockFirst, original)
    print("PASS login boundaries, calendar half-day precedence, earlier unlock retained")
}
