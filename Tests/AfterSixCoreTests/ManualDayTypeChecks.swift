import Foundation
import AfterSixCore

func checkManualDayTypes() throws {
    for selected in ManualDayType.allCases {
        expectEqual(selected.selectionOrder.first, selected)
        expectEqual(selected.selectionOrder.dropFirst().map { $0 }, ManualDayType.allCases.filter { $0 != selected })
    }
    let tests = AttendanceTests(), calendar = tests.calendar
    let morning = tests.date("2026-10-15T09:00:00")
    let afternoon = tests.date("2026-10-15T13:00:00")
    let now = tests.date("2026-10-15T16:00:00")
    let day = Attendance.dayKey(now, calendar: calendar)
    let adapter = DefaultAttendanceAdapter()
    var state = AttendanceState()
    _ = try adapter.apply(.dayType(.morningHalf, now: now), to: &state, calendar: calendar)
    expectNil(state.arrivals[day])
    expectFalse(Attendance.recordUnlock(in: &state, at: morning, calendar: calendar))
    expectTrue(Attendance.recordLogin(in: &state, at: afternoon, calendar: calendar, calendarMode: .normal))
    expectEqual(state.arrivals[day]?.mode, .morningHalf)
    expectEqual(state.arrivals[day]?.modeSource, .manual)
    expectFalse(Attendance.refreshAutomaticMode(in: &state, now: now, calendar: calendar, calendarMode: .normal))

    var pendingManual = AttendanceState()
    _ = try adapter.apply(.dayType(.afternoonHalf, now: now), to: &pendingManual, calendar: calendar)
    try Attendance.setManual(in: &pendingManual, at: morning, now: now, calendar: calendar,
                             selectedMode: nil, calendarMode: .morningHalf)
    expectEqual(pendingManual.arrivals[day]?.mode, .afternoonHalf)
    expectEqual(pendingManual.arrivals[day]?.modeSource, .manual)

    state = AttendanceState()
    expectTrue(Attendance.recordUnlock(in: &state, at: morning, calendar: calendar))
    let original = state.arrivals[day]!
    var annualAutomatic = state
    _ = try adapter.apply(.dayType(.annualLeave, now: now), to: &annualAutomatic, calendar: calendar)
    expectFalse(Attendance.refreshAutomaticMode(in: &annualAutomatic, now: now, calendar: calendar, calendarMode: .afternoonHalf))
    expectEqual(annualAutomatic.arrivals[day], original)

    let before = state
    expectThrows(try adapter.apply(.dayType(.morningHalf, now: now), to: &state, calendar: calendar))
    expectEqual(state, before)
    _ = try adapter.apply(.dayType(.afternoonHalf, now: now), to: &state, calendar: calendar)
    expectEqual(state.arrivals[day]?.time, original.time)
    expectEqual(state.arrivals[day]?.source, original.source)
    expectEqual(state.arrivals[day]?.timeZoneID, original.timeZoneID)
    expectEqual(state.arrivals[day]?.mode, .afternoonHalf)
    let half = state.arrivals[day]
    _ = try adapter.apply(.dayType(.annualLeave, now: now), to: &state, calendar: calendar)
    expectEqual(state.arrivals[day], half)
    expectTrue(state.suppressedDays.contains(day))
    expectNil(Attendance.today(in: state, now: now, calendar: calendar))
    expectNil(Attendance.postDepartureStatus(in: state, now: now, calendar: calendar))
    expectFalse(Attendance.recordLogin(in: &state, at: afternoon, calendar: calendar))
    expectFalse(Attendance.recordUnlock(in: &state, at: afternoon, calendar: calendar))
    let annualBeforeInvalidResume = state
    expectThrows(try adapter.apply(.dayType(.morningHalf, now: now), to: &state, calendar: calendar))
    expectEqual(state, annualBeforeInvalidResume)
    let decoded = try JSONDecoder().decode(AttendanceState.self, from: JSONEncoder().encode(state))
    expectEqual(decoded, state)
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
    legacy.removeValue(forKey: "manualDayTypes")
    let old = try JSONDecoder().decode(AttendanceState.self, from: JSONSerialization.data(withJSONObject: legacy))
    expectTrue(old.manualDayTypes.isEmpty)
    _ = try adapter.apply(.dayType(.regular, now: now), to: &state, calendar: calendar)
    expectFalse(state.suppressedDays.contains(day))
    expectEqual(Attendance.today(in: state, now: now, calendar: calendar)?.time, original.time)
    expectEqual(state.arrivals[day]?.mode, .normal)

    _ = try adapter.apply(.dayType(.annualLeave, now: now), to: &state, calendar: calendar)
    try Attendance.setManual(in: &state, at: morning, now: now, calendar: calendar, selectedMode: .afternoonHalf)
    expectEqual(state.manualDayTypes[day], .afternoonHalf)
    expectFalse(state.suppressedDays.contains(day))
    expectNotNil(Attendance.today(in: state, now: now, calendar: calendar))
    _ = try adapter.apply(.dayType(.annualLeave, now: now), to: &state, calendar: calendar)
    let next = tests.date("2026-10-16T09:00:00")
    expectTrue(Attendance.recordUnlock(in: &state, at: next, calendar: calendar))
    expectEqual(state.manualDayTypes[day], .annualLeave)
    expectEqual(state.arrivals["2026-10-16"]?.mode, .normal)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(url: directory.appendingPathComponent("state.json"))
    try store.save(state)
    try expectEqual(try store.load(), state)
    let data = try Data(contentsOf: store.url)
    let invalid = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "annualLeave", with: "unknownLeave")
    try Data(invalid.utf8).write(to: store.url)
    expectThrows(try store.load())
    try expectEqual(try Data(contentsOf: store.url), Data(invalid.utf8))
    var lulu = AttendanceState()
    _ = try adapter.apply(.dayType(.luluDay, now: now), to: &lulu, calendar: calendar)
    expectNil(lulu.arrivals[day])
    expectTrue(Attendance.recordUnlock(in: &lulu, at: morning, calendar: calendar))
    expectEqual(Attendance.departure(for: lulu.arrivals[day]!, settings: lulu.settings), tests.date("2026-10-15T16:00:00"))
    expectEqual(lulu.arrivals[day]?.earlyLeaveOverrideMinutes, 120)
    _ = try adapter.apply(.dayType(.regular, now: now), to: &lulu, calendar: calendar)
    expectEqual(Attendance.departure(for: lulu.arrivals[day]!, settings: lulu.settings), tests.date("2026-10-15T18:00:00"))
    _ = try adapter.apply(.dayType(.luluDay, now: now), to: &lulu, calendar: calendar)
    try Attendance.setManual(in: &lulu, at: morning, now: now, calendar: calendar)
    expectEqual(lulu.arrivals[day]?.earlyLeaveOverrideMinutes, 120)
    expectEqual(Attendance.postDepartureStatus(in: lulu, now: now, calendar: calendar)?.mealMinutesRemaining, 120)
    let luluRoundtrip = try JSONDecoder().decode(AttendanceState.self, from: JSONEncoder().encode(lulu))
    expectEqual(luluRoundtrip, lulu)
    var legacyLulu = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lulu)) as! [String: Any]
    var legacyArrivals = legacyLulu["arrivals"] as! [String: [String: Any]]
    legacyArrivals[day]!.removeValue(forKey: "earlyLeaveOverrideMinutes")
    legacyLulu["arrivals"] = legacyArrivals
    let legacyLuluDecoded = try JSONDecoder().decode(AttendanceState.self, from: JSONSerialization.data(withJSONObject: legacyLulu))
    expectNil(legacyLuluDecoded.arrivals[day]?.earlyLeaveOverrideMinutes)
    try store.save(lulu)
    var malformed = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
    var malformedArrivals = malformed["arrivals"] as! [String: [String: Any]]
    malformedArrivals[day]!["earlyLeaveOverrideMinutes"] = 999
    malformed["arrivals"] = malformedArrivals
    let malformedBytes = try JSONSerialization.data(withJSONObject: malformed)
    try malformedBytes.write(to: store.url)
    expectThrows(try store.load())
    try expectEqual(try Data(contentsOf: store.url), malformedBytes)
    let friday = tests.date("2026-10-30T09:00:00")
    var fridayState = AttendanceState()
    expectTrue(Attendance.recordUnlock(in: &fridayState, at: friday, calendar: calendar))
    expectEqual(Attendance.earlyLeaveMinutes(for: fridayState.arrivals["2026-10-30"]!), 120)
    _ = try adapter.apply(.dayType(.regular, now: friday), to: &fridayState, calendar: calendar)
    expectEqual(Attendance.earlyLeaveMinutes(for: fridayState.arrivals["2026-10-30"]!), 0)
    print("PASS Lulu day: pending selection, 120-minute override, regular restoration, manual correction, post-departure, persistence and Friday override")
    print("PASS manual day types: pending halves, calendar precedence, record preservation, annual leave, resume, next day and compatible persistence")
}
