import Foundation
import AfterSixCore

final class AttendanceTests {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return value
    }
    func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text + "+09:00")!
    }

    func testArrivalWindowsAndAutomaticMorningHalf() {
        var state = AttendanceState()
        for time in ["05:59:59", "10:01:00", "12:59:59", "15:01:00"] {
            expectFalse(Attendance.recordUnlock(in: &state, at: date("2026-09-28T" + time), calendar: calendar))
        }
        expectTrue(Attendance.recordUnlock(in: &state, at: date("2026-09-28T08:00:00"), calendar: calendar))
        expectEqual(state.arrivals["2026-09-28"]?.mode, .normal)
        for time in ["10:00:59", "13:00:00", "15:00:59"] {
            let mode = Attendance.automaticMode(at: date("2026-09-29T" + time), calendar: calendar)
            expectEqual(mode, time.hasPrefix("10") ? .normal : .morningHalf)
        }
        expectEqual(Attendance.automaticMode(at: date("2026-09-29T15:01:00"), calendar: calendar), nil)
    }

    func testLaterUnlockDoesNotReplaceFirstArrival() {
        var state = AttendanceState()
        let first = date("2026-09-28T08:47:12")
        Attendance.recordUnlock(in: &state, at: first, calendar: calendar)
        expectFalse(Attendance.recordUnlock(in: &state, at: date("2026-09-28T13:00:00"), calendar: calendar))
        expectEqual(state.arrivals["2026-09-28"]?.time, first)
        expectEqual(state.lastUnlockAt, date("2026-09-28T13:00:00"))
    }

    func testNewDayHasIndependentFirstUnlock() {
        var state = AttendanceState()
        Attendance.recordUnlock(in: &state, at: date("2026-09-28T08:47:00"), calendar: calendar)
        expectNil(Attendance.today(in: state, now: date("2026-09-29T05:00:00"), calendar: calendar))
        expectFalse(Attendance.recordUnlock(in: &state, at: date("2026-09-29T05:00:00"), calendar: calendar))
        expectTrue(Attendance.recordUnlock(in: &state, at: date("2026-09-29T09:00:00"), calendar: calendar))
        expectEqual(state.arrivals.count, 2)
    }

    func testDepartureIncludesBreak() {
        var state = AttendanceState()
        Attendance.recordUnlock(in: &state, at: date("2026-09-28T08:47:00"), calendar: calendar)
        let departure = Attendance.departure(for: state.arrivals["2026-09-28"]!, settings: state.settings)
        expectEqual(departure, date("2026-09-28T17:47:00"))
        expectEqual(Attendance.remainingMinutes(until: departure, now: date("2026-09-28T15:12:00")), 155)
    }

    func testLastFridayAcrossMonthLengthsAndYearEnd() {
        for day in ["2026-09-25", "2026-10-30", "2024-02-23", "2025-02-28", "2027-12-31"] {
            expectEqual(Attendance.earlyLeaveMinutes(on: date(day + "T09:00:00"), timeZone: calendar.timeZone), 120)
        }
        for day in ["2026-09-18", "2026-09-24", "2026-09-26", "2026-09-30", "2026-10-23", "2024-02-29", "2027-12-24", "2027-12-30"] {
            expectEqual(Attendance.earlyLeaveMinutes(on: date(day + "T09:00:00"), timeZone: calendar.timeZone), 0)
        }
    }

    func testLastFridayDepartureCountdownAndProgress() {
        var state = AttendanceState()
        let start = date("2026-10-30T09:00:00")
        Attendance.recordUnlock(in: &state, at: start, calendar: calendar)
        let end = Attendance.departure(for: state.arrivals["2026-10-30"]!, settings: state.settings)
        expectEqual(end, date("2026-10-30T16:00:00"))
        expectEqual(Attendance.remainingMinutes(until: end, now: date("2026-10-30T15:59:59")), 1)
        expectEqual(Attendance.remainingMinutes(until: end, now: end), 0)
        expectEqual(Attendance.remainingMinutes(until: end, now: date("2026-10-30T17:00:00")), 0)
        expectEqual(Attendance.progress(from: start, until: end, now: date("2026-10-30T12:30:00")), 0.5)
        expectEqual(Attendance.progress(from: start, until: end, now: start.addingTimeInterval(-1)), 0)
        expectEqual(Attendance.progress(from: start, until: end, now: end.addingTimeInterval(1)), 1)
    }

    func testRegularFridayKeepsNormalDeparture() {
        let start = date("2026-10-23T09:00:00")
        let record = Arrival(day: "2026-10-23", time: start, source: .manual, timeZoneID: calendar.timeZone.identifier)
        expectEqual(Attendance.departure(for: record, settings: WorkSettings()), date("2026-10-23T18:00:00"))
    }

    func testEarlyLeaveUsesRecordedTimeZone() {
        // This instant is Friday in Seoul and Thursday in Los Angeles and UTC.
        let instant = date("2026-10-30T08:30:00")
        let seoul = Arrival(day: "2026-10-30", time: instant, source: .unlock, timeZoneID: "Asia/Seoul")
        let losAngeles = Arrival(day: "2026-10-29", time: instant, source: .unlock, timeZoneID: "America/Los_Angeles")
        expectEqual(Attendance.departure(for: seoul, settings: WorkSettings()).timeIntervalSince(instant), 7 * 3600)
        expectEqual(Attendance.departure(for: losAngeles, settings: WorkSettings()).timeIntervalSince(instant), 9 * 3600)
        expectEqual(Attendance.earlyLeaveMinutes(on: instant, timeZone: TimeZone(secondsFromGMT: 0)!), 0)
        expectEqual(Attendance.earlyLeaveMinutes(on: date("2026-10-30T23:59:59"), timeZone: calendar.timeZone), 120)
        expectEqual(Attendance.earlyLeaveMinutes(on: date("2026-10-31T00:00:00"), timeZone: calendar.timeZone), 0)
    }

    func testEarlyLeaveWithCustomSettingsAndShortDays() {
        let start = date("2026-10-30T09:00:00")
        let record = Arrival(day: "2026-10-30", time: start, source: .manual, timeZoneID: calendar.timeZone.identifier)
        var settings = WorkSettings()
        settings.workMinutes = 360
        settings.breakMinutes = 30
        expectEqual(Attendance.departure(for: record, settings: settings), date("2026-10-30T13:30:00"))
        expectEqual(settings.workMinutes, 360)
        expectEqual(settings.breakMinutes, 30)
        settings.workMinutes = 60
        for rest in [0, 60] {
            settings.breakMinutes = rest
            let end = Attendance.departure(for: record, settings: settings)
            expectEqual(end, start)
            expectEqual(Attendance.remainingMinutes(until: end, now: start), 0)
            expectEqual(Attendance.progress(from: start, until: end, now: start), 1)
            expectEqual(Attendance.progress(from: start, until: end, now: start.addingTimeInterval(-1)), 0)
        }
    }

    func testEarlyLeaveManualArrivalPersistsWithoutSchemaChange() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HappyLulu-friday-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("state.json"))
        var state = AttendanceState()
        let now = date("2026-10-30T12:00:00")
        try Attendance.setManual(in: &state, at: date("2026-10-30T08:30:00"), now: now, calendar: calendar)
        try store.save(state)
        let loaded = try store.load()
        expectEqual(loaded.version, 1)
        expectEqual(loaded, state)
        expectEqual(Attendance.departure(for: loaded.arrivals["2026-10-30"]!, settings: loaded.settings), date("2026-10-30T15:30:00"))
    }

    func testRemainingTimeCeilsAndClamps() {
        let end = date("2026-09-28T17:47:00")
        expectEqual(Attendance.remainingMinutes(until: end, now: end.addingTimeInterval(-1)), 1)
        expectEqual(Attendance.remainingMinutes(until: end, now: end), 0)
        expectEqual(Attendance.remainingMinutes(until: end, now: end.addingTimeInterval(3600)), 0)
    }

    func testClockLabelsUse24HoursAndRecordedZone() {
        let sample = date("2026-09-28T17:55:00")
        expectEqual(Attendance.clockLabel(sample, timeZone: calendar.timeZone), "17:55")
        expectEqual(Attendance.clockLabel(sample, timeZone: TimeZone(secondsFromGMT: 0)!), "08:55")
        expectEqual(Attendance.clockLabel(date("2026-09-28T00:05:00"), timeZone: calendar.timeZone), "00:05")
    }

    func testManualCorrectionSurvivesLaterUnlock() throws {
        var state = AttendanceState()
        let now = date("2026-09-28T12:00:00")
        Attendance.recordUnlock(in: &state, at: now, calendar: calendar)
        try Attendance.setManual(in: &state, at: date("2026-09-28T08:30:00"), now: now, calendar: calendar)
        Attendance.recordUnlock(in: &state, at: date("2026-09-28T13:00:00"), calendar: calendar)
        expectEqual(state.arrivals["2026-09-28"]?.time, date("2026-09-28T08:30:00"))
        expectEqual(state.arrivals["2026-09-28"]?.source, .manual)
    }

    func testRejectsFutureAndOtherDayWithoutMutation() throws {
        var state = AttendanceState()
        let original = state
        let now = date("2026-09-28T12:00:00")
        expectThrows(try Attendance.setManual(in: &state, at: date("2026-09-28T13:00:00"), now: now, calendar: calendar))
        expectThrows(try Attendance.setManual(in: &state, at: date("2026-09-27T09:00:00"), now: now, calendar: calendar))
        expectEqual(state, original)
    }

    func testManualOutsideArrivalWindowIsRejected() throws {
        var state = AttendanceState()
        let now = date("2026-09-28T16:00:00")
        for time in ["05:30:00", "10:01:00", "12:59:00", "15:01:00"] {
            expectThrows(try Attendance.setManual(in: &state, at: date("2026-09-28T" + time), now: now, calendar: calendar))
        }
        expectTrue(state.arrivals.isEmpty)
    }

    func testDayOffSuppressesLaterUnlockAndManualResumes() throws {
        var state = AttendanceState()
        let now = date("2026-09-28T12:00:00")
        Attendance.recordUnlock(in: &state, at: date("2026-09-28T09:00:00"), calendar: calendar)
        Attendance.skipToday(in: &state, now: now, calendar: calendar)
        expectFalse(Attendance.recordUnlock(in: &state, at: now, calendar: calendar))
        expectNil(state.arrivals["2026-09-28"])
        try Attendance.setManual(in: &state, at: date("2026-09-28T09:00:00"), now: now, calendar: calendar)
        expectNotNil(state.arrivals["2026-09-28"])
        expectFalse(state.suppressedDays.contains("2026-09-28"))
    }

    func testDayOffDoesNotSuppressNextDay() {
        var state = AttendanceState()
        Attendance.skipToday(in: &state, now: date("2026-09-28T12:00:00"), calendar: calendar)
        expectTrue(Attendance.recordUnlock(in: &state, at: date("2026-09-29T08:00:00"), calendar: calendar))
    }

    func testLocalDayDoesNotUseUTCDate() {
        var state = AttendanceState()
        Attendance.recordUnlock(in: &state, at: date("2026-09-28T08:00:00"), calendar: calendar)
        expectNotNil(state.arrivals["2026-09-28"])
        expectNil(state.arrivals["2026-09-27"])
    }

    func testCountdownUsesElapsedTimeAcrossDST() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = ISO8601DateFormatter().date(from: "2026-03-08T00:00:00-08:00")!
        let record = Arrival(day: "2026-03-08", time: start, source: .manual, timeZoneID: cal.timeZone.identifier)
        let end = Attendance.departure(for: record, settings: WorkSettings())
        expectEqual(end.timeIntervalSince(start), 9 * 3600)
        expectEqual(cal.component(.hour, from: end), 10)
    }

    func testPersistenceAndRestartDoNotOverwriteArrival() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AfterSix-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("state.json"))
        var original = AttendanceState()
        Attendance.recordUnlock(in: &original, at: date("2026-09-28T08:47:00"), calendar: calendar)
        try store.save(original)
        var loaded = try store.load()
        expectEqual(loaded, original)
        expectFalse(Attendance.recordUnlock(in: &loaded, at: date("2026-09-28T15:00:00"), calendar: calendar))
        expectEqual(loaded.arrivals, original.arrivals)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        expectEqual(mode, 0o600)
    }

    func testMissingFileDoesNotInventAttendanceOrWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AfterSix-missing-\(UUID().uuidString)/state.json")
        let state = try StateStore(url: url).load()
        expectTrue(state.arrivals.isEmpty)
        expectFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptFileIsPreserved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AfterSix-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("not valid json".utf8)
        try data.write(to: url)
        expectThrows(try StateStore(url: url).load())
        try expectEqual(try Data(contentsOf: url), data)
    }

    func testInvalidSettingsCannotOverwriteFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AfterSix-invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("state.json"))
        let state = AttendanceState()
        try store.save(state)
        var bad = state
        bad.settings.workMinutes = -1
        expectThrows(try store.save(bad))
        try expectEqual(try store.load(), state)
    }

    func testUnknownSchemaIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AfterSix-schema-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var state = AttendanceState()
        state.version = 99
        try JSONEncoder().encode(state).write(to: url)
        expectThrows(try StateStore(url: url).load())
    }

    func testCalendarAndManualModePrecedence() throws {
        var state = AttendanceState()
        let atNine = date("2026-09-28T09:00:00")
        expectFalse(Attendance.recordUnlock(in: &state, at: atNine, calendar: calendar,
                                            calendarMode: .morningHalf))
        expectTrue(Attendance.recordUnlock(in: &state, at: atNine, calendar: calendar,
                                           calendarMode: .afternoonHalf))
        expectEqual(state.arrivals["2026-09-28"]?.mode, .afternoonHalf)
        expectEqual(Attendance.departure(for: state.arrivals["2026-09-28"]!, settings: state.settings),
                    date("2026-09-28T13:00:00"))
        let now = date("2026-09-28T16:00:00")
        try Attendance.setManual(in: &state, at: atNine, now: now, calendar: calendar,
                                 selectedMode: .normal, calendarMode: .afternoonHalf)
        expectEqual(state.arrivals["2026-09-28"]?.mode, .normal)
        expectEqual(state.arrivals["2026-09-28"]?.modeSource, .manual)
        expectFalse(Attendance.refreshAutomaticMode(in: &state, now: now, calendar: calendar,
                                                    calendarMode: .afternoonHalf))
        expectEqual(Attendance.departure(for: state.arrivals["2026-09-28"]!, settings: state.settings),
                    date("2026-09-28T18:00:00"))
        try Attendance.setManual(in: &state, at: atNine, now: now, calendar: calendar,
                                 selectedMode: .afternoonHalf)
        expectEqual(Attendance.departure(for: state.arrivals["2026-09-28"]!, settings: state.settings),
                    date("2026-09-28T13:00:00"))
    }

    func testMorningHalfAndLastFridayDoNotStack() throws {
        var state = AttendanceState()
        let now = date("2026-10-30T16:00:00")
        try Attendance.setManual(in: &state, at: date("2026-10-30T13:00:00"), now: now,
                                 calendar: calendar)
        expectEqual(state.arrivals["2026-10-30"]?.mode, .morningHalf)
        expectEqual(Attendance.departure(for: state.arrivals["2026-10-30"]!, settings: state.settings),
                    date("2026-10-30T17:00:00"))
        try Attendance.setManual(in: &state, at: date("2026-10-30T09:00:00"), now: now,
                                 calendar: calendar, selectedMode: .afternoonHalf)
        expectEqual(Attendance.departure(for: state.arrivals["2026-10-30"]!, settings: state.settings),
                    date("2026-10-30T13:00:00"))
    }

    func testCalendarModeRefreshOnlyChangesAutomaticChoice() throws {
        var state = AttendanceState()
        let start = date("2026-09-28T09:00:00")
        Attendance.recordUnlock(in: &state, at: start, calendar: calendar)
        expectTrue(Attendance.refreshAutomaticMode(in: &state, now: start, calendar: calendar,
                                                   calendarMode: .afternoonHalf))
        expectEqual(state.arrivals["2026-09-28"]?.mode, .afternoonHalf)
        expectTrue(Attendance.refreshAutomaticMode(in: &state, now: start, calendar: calendar,
                                                   calendarMode: .morningHalf))
        expectEqual(state.arrivals["2026-09-28"]?.mode, .normal)
        expectEqual(Attendance.departure(for: state.arrivals["2026-09-28"]!, settings: state.settings),
                    date("2026-09-28T18:00:00"))
        expectFalse(Attendance.refreshAutomaticMode(in: &state, now: start, calendar: calendar,
                                                    calendarMode: nil))
        expectEqual(CalendarModeObservation.confirmed(nil).resolved(previous: .afternoonHalf), nil)
        expectEqual(CalendarModeObservation.unavailable.resolved(previous: .afternoonHalf), .afternoonHalf)
    }

    func testLegacyStateDecodesWithoutHalfDayFields() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HappyLulu-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("state.json"))
        var state = AttendanceState()
        Attendance.recordUnlock(in: &state, at: date("2026-09-28T09:00:00"), calendar: calendar)
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        raw.removeValue(forKey: "detectHalfDaysFromCalendar")
        var arrivals = raw["arrivals"] as! [String: [String: Any]]
        arrivals["2026-09-28"]?.removeValue(forKey: "mode")
        arrivals["2026-09-28"]?.removeValue(forKey: "modeSource")
        raw["arrivals"] = arrivals
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: raw).write(to: store.url)
        let loaded = try store.load()
        expectEqual(loaded.arrivals["2026-09-28"]?.mode, .normal)
        expectEqual(loaded.arrivals["2026-09-28"]?.modeSource, .legacy)
        expectFalse(loaded.detectHalfDaysFromCalendar)
        try store.save(loaded)
        try expectEqual(try store.load(), loaded)
    }

    func testCalendarTitleRecognitionRejectsAmbiguity() {
        expectEqual(HalfDayRecognition.mode(from: ["오전 반차"]), .morningHalf)
        expectEqual(HalfDayRecognition.mode(from: ["반차(오후)"]), .afternoonHalf)
        expectEqual(HalfDayRecognition.mode(from: ["반차"]), nil)
        expectEqual(HalfDayRecognition.mode(from: ["오전 반차", "오후 반차"]), nil)
        expectEqual(HalfDayRecognition.mode(from: ["오전 반차 취소"]), nil)
    }

    func testPostDepartureThirtyAndMealBoundaries() {
        var state = AttendanceState()
        let arrival = date("2026-09-28T09:00:00")
        let day = "2026-09-28"
        state.arrivals[day] = Arrival(day: day, time: arrival, source: .manual,
                                      timeZoneID: calendar.timeZone.identifier)
        let departure = date("2026-09-28T18:00:00")
        func status(_ seconds: TimeInterval) -> PostDepartureStatus? {
            Attendance.postDepartureStatus(in: state, now: departure.addingTimeInterval(seconds),
                                            calendar: calendar)
        }
        expectNil(status(-1))
        expectEqual(status(0)?.extraMinutes, nil)
        expectEqual(status(0)?.mealMinutesRemaining, 120)
        expectEqual(status(29 * 60 + 59)?.extraMinutes, nil)
        expectEqual(status(29 * 60 + 59)?.mealMinutesRemaining, 91)
        expectEqual(status(30 * 60)?.extraMinutes, 30)
        expectEqual(status(30 * 60)?.mealMinutesRemaining, 90)
        expectEqual(status(30 * 60 + 59)?.extraMinutes, 30)
        expectEqual(status(30 * 60 + 59)?.mealMinutesRemaining, 90)
        expectEqual(status(31 * 60)?.extraMinutes, 31)
        expectEqual(status(31 * 60)?.mealMinutesRemaining, 89)
        expectEqual(status(119 * 60 + 59)?.extraMinutes, 119)
        expectEqual(status(119 * 60 + 59)?.mealMinutesRemaining, 1)
        expectFalse(status(119 * 60 + 59)!.mealThresholdReached)
        expectEqual(status(120 * 60)?.extraMinutes, 120)
        expectEqual(status(120 * 60)?.mealMinutesRemaining, 0)
        expectTrue(status(120 * 60)!.mealThresholdReached)
        expectEqual(status(120 * 60 + 59)?.extraMinutes, 120)
        expectEqual(status(120 * 60 + 59)?.mealMinutesRemaining, 0)
        state.suppressedDays.insert(day)
        expectNil(status(120 * 60))
        state.arrivals.removeValue(forKey: day)
        state.suppressedDays.remove(day)
        expectNil(status(120 * 60))
    }

    func testPostDepartureUsesHalfDayAndLastFridayDeparture() {
        let day = "2026-10-30" // Last Friday of the month.
        for (arrivalTime, mode, scheduledDeparture) in [
            ("09:00:00", WorkdayMode.normal, "16:00:00"),
            ("13:00:00", .morningHalf, "17:00:00"),
            ("09:00:00", .afternoonHalf, "13:00:00")
        ] {
            var state = AttendanceState()
            state.arrivals[day] = Arrival(day: day, time: date("\(day)T\(arrivalTime)"),
                                          source: .manual, timeZoneID: calendar.timeZone.identifier,
                                          mode: mode)
            let expected = date("\(day)T\(scheduledDeparture)")
            expectEqual(Attendance.departure(for: state.arrivals[day]!, settings: state.settings), expected)
            expectNil(Attendance.postDepartureStatus(in: state, now: expected.addingTimeInterval(-1),
                                                      calendar: calendar))
            let status = Attendance.postDepartureStatus(in: state,
                                                         now: expected.addingTimeInterval(31 * 60),
                                                         calendar: calendar)
            expectEqual(status?.extraMinutes, 31)
            expectEqual(status?.mealMinutesRemaining, 89)
        }
    }
    func testInvalidArrivalCannotOverwriteFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HappyLulu-invalid-arrival-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("state.json"))
        var valid = AttendanceState()
        Attendance.recordUnlock(in: &valid, at: date("2026-09-28T09:00:00"), calendar: calendar)
        try store.save(valid)
        let original = try Data(contentsOf: store.url)
        for (key, day, zone) in [
            ("wrong-key", "2026-09-28", "Asia/Seoul"),
            ("2026-09-28", "2026-09-28", "Invalid/Zone")
        ] {
            var invalid = valid
            invalid.arrivals = [key: Arrival(day: day, time: date("2026-09-28T09:00:00"),
                                             source: .manual, timeZoneID: zone)]
            expectThrows(try store.save(invalid))
            try expectEqual(Data(contentsOf: store.url), original)
            try expectEqual(store.load(), valid)
        }
    }

}
