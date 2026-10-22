import Foundation
import AppPluginCore

func checkVacationPreview() {
    let now = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00+09:00")!
    let target = ISO8601DateFormatter().date(from: "2026-10-23T12:00:00+09:00")!
    let seoul = TimeZone(identifier: "Asia/Seoul")!
    func leave(kind: String = "연차", status: String = "APPROVAL", days: Double? = 1,
               dates: [String] = ["2026-10-23"], start: String? = nil, end: String? = nil) -> PluginVacation {
        PluginVacation(id: "fixture", kind: kind, status: status, days: days, dates: dates,
                       periodLabel: "synthetic", rangeStart: start, rangeEnd: end)
    }
    func snapshot(_ vacations: [PluginVacation], fetchedAt: Date? = nil,
                  events: [PluginCalendarEvent] = [], leaveYear: Int? = 2026) -> PluginSnapshot {
        PluginSnapshot(pluginID: "fixture", fetchedAt: fetchedAt ?? now, leave: nil,
                       vacations: vacations, events: events, coverage: PluginCoverage(leaveYear: leaveYear))
    }
    func eligible(_ vacation: PluginVacation) -> Bool {
        snapshot([vacation]).hasConfirmedFullDayLeave(on: target, timeZone: seoul, now: now)
    }

    for kind in ["연차", "공가", "연차/공가", " \n연차\t"] {
        require(eligible(leave(kind: kind)), "Approved full-day leave of an exact supported kind must qualify")
    }
    require(eligible(leave(status: " \nAPPROVAL\t")), "Only surrounding status whitespace may be trimmed")
    for status in ["", "PENDING", "INPROGRESS", "CREATE", "TEMPSAVE", "CANCEL", "RETURN", "APPROVED", "Approved", "approval", "APPROVAL_CANCEL", "APP ROVAL"] {
        require(!eligible(leave(status: status)), "Unconfirmed status must not qualify: \(status)")
    }
    for kind in ["", "오전반차", "오후반차", "연차 반차", "연차휴가", "특별공가", "연차 / 공가", "연 차", "휴가"] {
        require(!eligible(leave(kind: kind)), "Unknown or substring-only leave kind must not qualify: \(kind)")
    }
    for days: Double? in [nil, 0, -1, 0.5, 1.5, 2, .nan, .infinity, -.infinity] {
        require(!eligible(leave(days: days)), "Uncertain or non-full-day duration must not qualify")
    }
    let halfDays = snapshot([leave(days: 0.5), leave(days: 0.5)])
    require(!halfDays.hasConfirmedFullDayLeave(on: target, timeZone: seoul, now: now),
            "Separate half-day records must not be combined into confirmed full-day leave")

    require(eligible(leave(days: 2, dates: ["2026-10-23", "2026-10-26"])),
            "Every explicit full day must qualify when duration matches the unique date count")
    let nonconsecutive = snapshot([leave(days: 2, dates: ["2026-10-23", "2026-10-26"])])
    let weekend = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00+09:00")!
    require(!nonconsecutive.hasConfirmedFullDayLeave(on: weekend, timeZone: seoul, now: now),
            "Missing weekend dates must never be filled in")
    require(!eligible(leave(dates: [])), "Missing source dates must not qualify")
    require(!eligible(leave(dates: ["2026-10-22"])), "A different source day must not qualify")
    for days in [1.0, 2.0] {
        require(!eligible(leave(days: days, dates: ["2026-10-23", "2026-10-23"])),
                "Duplicate dates must fail even if duration matches the unique or raw count")
    }
    for invalid in ["", "2026-10-3", "2026-1-23", "2026-02-30", "2026-02-29", "2026-13-01",
                    "2026-10-23T00:00:00+09:00", " 2026-10-23", "2026-10-23 ", "２０２６-１０-２３"] {
        require(!eligible(leave(days: 2, dates: ["2026-10-23", invalid])),
                "An invalid explicit date must invalidate the record: \(invalid)")
    }
    require(!eligible(leave(days: 1, dates: ["2026-10-23", "2026-10-26"])),
            "Duration must equal the number of explicit dates")

    require(eligible(leave(dates: [], start: "2026-10-23", end: "2026-10-23")),
            "A single-day range with exactly one day must qualify")
    for (start, end, days): (String?, String?, Double?) in [
        (nil, "2026-10-23", 1), ("2026-10-23", nil, 1), ("", "", 1),
        ("2026-10-22", "2026-10-22", 1), ("2026-10-23", "2026-10-26", 1),
        ("2026-10-23", "2026-10-26", 2), ("2026-10-26", "2026-10-23", 1),
        ("2026-02-30", "2026-02-30", 1), (" 2026-10-23", " 2026-10-23", 1),
        ("2026-10-23", "2026-10-23", 0.5), ("2026-10-23", "2026-10-23", nil)
    ] {
        require(!eligible(leave(days: days, dates: [], start: start, end: end)),
                "Missing, multi-day, malformed, reversed or partial-day ranges must fail closed")
    }
    require(!eligible(leave(start: "2026-10-23", end: "2026-10-23")),
            "Mixed explicit dates and range fields are ambiguous even if they agree")
    require(!eligible(leave(start: "2026-10-26")), "A partial range must not be ignored beside explicit dates")
    require(!eligible(leave(dates: ["invalid"], start: "2026-10-23", end: "2026-10-23")),
            "Invalid explicit dates must not fall back to a valid range")

    for (age, expected) in [(0.0, true), (899.999, true), (900.0, true), (900.001, false), (-0.001, false)] {
        require(snapshot([leave()], fetchedAt: now.addingTimeInterval(-age))
            .hasConfirmedFullDayLeave(on: target, timeZone: seoul, now: now) == expected,
            "Freshness must allow at most 15 minutes and never a future snapshot")
    }
    let historicalNow = Date(timeIntervalSince1970: -60)
    require(snapshot([leave(dates: ["1970-01-01"])], fetchedAt: historicalNow)
        .hasConfirmedFullDayLeave(on: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!, now: historicalNow),
        "Freshness depends on age, not an arbitrary positive Unix timestamp requirement")
    for value in [Double.nan, .infinity, -.infinity] {
        require(!snapshot([leave()], fetchedAt: Date(timeIntervalSince1970: value))
            .hasConfirmedFullDayLeave(on: target, timeZone: seoul, now: now),
            "Nonfinite fetchedAt must fail closed")
    }
    for value in [Double.nan, .infinity, -.infinity] {
        require(!snapshot([leave()]).hasConfirmedFullDayLeave(on: target, timeZone: seoul,
                                                          now: Date(timeIntervalSince1970: value)),
                "Nonfinite current time must fail closed")
        require(!snapshot([leave()]).hasConfirmedFullDayLeave(on: Date(timeIntervalSince1970: value),
                                                          timeZone: seoul, now: now),
                "Nonfinite target day must fail closed")
    }

    for (zone, instant, localDate, otherDate) in [
        ("Asia/Seoul", "2026-11-01T00:00:00+09:00", "2026-11-01", "2026-10-31"),
        ("Asia/Seoul", "2027-01-01T00:00:00+09:00", "2027-01-01", "2026-12-31"),
        ("America/New_York", "2026-03-08T23:30:00-04:00", "2026-03-08", "2026-03-09"),
        ("America/New_York", "2026-11-01T23:30:00-05:00", "2026-11-01", "2026-11-02"),
        ("Asia/Seoul", "2028-02-29T00:00:00+09:00", "2028-02-29", "2028-02-28")
    ] {
        let day = ISO8601DateFormatter().date(from: instant)!
        let timeZone = TimeZone(identifier: zone)!
        require(snapshot([leave(dates: [localDate])]).hasConfirmedFullDayLeave(on: day, timeZone: timeZone, now: now),
                "Exact source civil dates must work across month, year, leap-day and DST boundaries")
        require(!snapshot([leave(dates: [otherDate])]).hasConfirmedFullDayLeave(on: day, timeZone: timeZone, now: now),
                "UTC conversion must not shift the source civil date")
        require(snapshot([leave(dates: [], start: localDate, end: localDate)], leaveYear: nil)
            .hasConfirmedFullDayLeave(on: day, timeZone: timeZone, now: now),
            "Exact range dates must use the source time zone and not depend on coverage year")
    }
    let event = PluginCalendarEvent(id: "event", calendarID: "calendar", title: "연차", start: target, isAllDay: true)
    require(!snapshot([], events: [event]).hasConfirmedFullDayLeave(on: target, timeZone: seoul, now: now),
            "Calendar titles cannot establish approved leave")
    require(snapshot([leave(status: "CANCEL"), leave()]).hasConfirmedFullDayLeave(on: target, timeZone: seoul, now: now),
            "One independently confirmed record must still qualify among rejected records")
    print("PASS vacation preview: approved exact kinds, full days, strict dates/ranges, freshness, source time zones and fail-closed uncertainty")
}
