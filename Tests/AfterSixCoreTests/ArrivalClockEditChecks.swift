import Foundation
import AfterSixCore

func checkArrivalClockEdit() {
    let zone = TimeZone(identifier: "Asia/Seoul")!
    let now = ISO8601DateFormatter().date(from: "2026-10-16T00:42:37Z")!
    var fresh = ArrivalClockEdit(existingTime: nil, now: now, timeZone: zone)
    expectEqual(fresh.text, "09:42")
    expectTrue(fresh.needsSave) // Unchanged default must create a record on dismissal.
    var existing = ArrivalClockEdit(existingTime: now, now: now.addingTimeInterval(3600), timeZone: zone)
    expectFalse(existing.needsSave)
    existing.replaceDigit(at: 3, with: "3")
    expectEqual(existing.text, "09:43")
    expectTrue(existing.needsSave)
    expectTrue(fresh.adjustDigit(at: 0, by: 1))
    expectEqual(fresh.text, "19:42")
    expectFalse(fresh.adjustDigit(at: 0, by: 1)) // 29 is not an hour.
    expectTrue(fresh.adjustDigit(at: 1, by: -1))
    expectEqual(fresh.text, "18:42")
    expectTrue(fresh.adjustDigit(at: 2, by: 1))
    expectEqual(fresh.text, "18:52")
    expectTrue(fresh.adjustDigit(at: 3, by: 1))
    expectEqual(fresh.text, "18:53")
    fresh.replaceDigit(at: 0, with: "23:59")
    expectEqual(fresh.text, "23:59")
    for index in 0..<4 { expectFalse(fresh.adjustDigit(at: index, by: 1)) }
    fresh.replaceDigit(at: 0, with: "0000")
    expectEqual(fresh.text, "00:00")
    for index in 0..<4 { expectFalse(fresh.adjustDigit(at: index, by: -1)) }
    fresh.replaceDigit(at: 0, with: "10") // Insert 1 before the existing 0 in a native field.
    expectEqual(fresh.text, "10:00")
    fresh.replaceDigit(at: 0, with: "12") // Insert 2 after the existing 1.
    expectEqual(fresh.text, "20:00")
    fresh.replaceDigit(at: 0, with: "0000")
    fresh.replaceDigit(at: 2, with: "9")
    expectEqual(fresh.text, "00:90") // Invalid direct input remains visible for save validation.
    fresh.replaceDigit(at: 2, with: "")
    expectEqual(fresh.text, "00:0")
    fresh.replaceDigit(at: 2, with: "x")
    expectEqual(fresh.text, "00:0")
    print("PASS arrival clock edit: current default needs save, existing unchanged, four digit edits and bounded adjustments")
}
