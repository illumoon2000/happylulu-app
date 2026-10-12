import Foundation
import AfterSixCore

func failure(_ message: String, file: StaticString, line: UInt) -> Never {
    FileHandle.standardError.write(Data("FAIL \(file):\(line): \(message)\n".utf8))
    exit(1)
}
func expectEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) rethrows {
    let a = try lhs(), b = try rhs()
    if a != b { failure("\(a) != \(b)", file: file, line: line) }
}
func expectTrue(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value() { failure("Expected true", file: file, line: line) }
}
func expectFalse(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if value() { failure("Expected false", file: file, line: line) }
}
func expectNil<T>(_ value: @autoclosure () -> T?, file: StaticString = #filePath, line: UInt = #line) {
    if value() != nil { failure("Expected nil", file: file, line: line) }
}
func expectNotNil<T>(_ value: @autoclosure () -> T?, file: StaticString = #filePath, line: UInt = #line) {
    if value() == nil { failure("Expected non-nil", file: file, line: line) }
}
func expectThrows<T>(_ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try value() } catch { return }
    failure("Expected an error", file: file, line: line)
}

try checkEarlyArrival()

let tests = AttendanceTests()
let checks: [(String, () throws -> Void)] = [
    ("Month grid, leap year, year rollover and exclusive event ends across DST", checkCalendarMonth),
    ("Arrival windows and automatic morning half", tests.testArrivalWindowsAndAutomaticMorningHalf),
    ("First unlock wins", tests.testLaterUnlockDoesNotReplaceFirstArrival),
    ("New day", tests.testNewDayHasIndependentFirstUnlock),
    ("Work plus break", tests.testDepartureIncludesBreak),
    ("Last Friday across month lengths and year end", tests.testLastFridayAcrossMonthLengthsAndYearEnd),
    ("Early departure countdown and progress", tests.testLastFridayDepartureCountdownAndProgress),
    ("Regular Friday unchanged", tests.testRegularFridayKeepsNormalDeparture),
    ("Early leave recorded timezone", tests.testEarlyLeaveUsesRecordedTimeZone),
    ("Custom and short workdays", tests.testEarlyLeaveWithCustomSettingsAndShortDays),
    ("Manual early leave persistence", tests.testEarlyLeaveManualArrivalPersistsWithoutSchemaChange),
    ("Countdown rounding", tests.testRemainingTimeCeilsAndClamps),
    ("24-hour clock and timezone", tests.testClockLabelsUse24HoursAndRecordedZone),
    ("Manual correction", tests.testManualCorrectionSurvivesLaterUnlock),
    ("Invalid manual dates", tests.testRejectsFutureAndOtherDayWithoutMutation),
    ("Manual arrival window", tests.testManualOutsideArrivalWindowIsRejected),
    ("Day off and resume", tests.testDayOffSuppressesLaterUnlockAndManualResumes),
    ("Day off expires", tests.testDayOffDoesNotSuppressNextDay),
    ("Local calendar day", tests.testLocalDayDoesNotUseUTCDate),
    ("DST elapsed duration", tests.testCountdownUsesElapsedTimeAcrossDST),
    ("Persistence and restart", tests.testPersistenceAndRestartDoNotOverwriteArrival),
    ("No invented arrival", tests.testMissingFileDoesNotInventAttendanceOrWrite),
    ("Corrupt file preserved", tests.testCorruptFileIsPreserved),
    ("Invalid arrival preserves file", tests.testInvalidArrivalCannotOverwriteFile),
    ("Invalid settings", tests.testInvalidSettingsCannotOverwriteFile),
    ("Unknown schema", tests.testUnknownSchemaIsRejected),
    ("Calendar and manual precedence", tests.testCalendarAndManualModePrecedence),
    ("Half day and last Friday", tests.testMorningHalfAndLastFridayDoNotStack),
    ("Calendar mode refresh", tests.testCalendarModeRefreshOnlyChangesAutomaticChoice),
    ("Legacy state compatibility", tests.testLegacyStateDecodesWithoutHalfDayFields),
    ("Calendar title ambiguity", tests.testCalendarTitleRecognitionRejectsAmbiguity),
    ("Post-departure thirty and meal boundaries", tests.testPostDepartureThirtyAndMealBoundaries),
    ("Post-departure half-day and last Friday", tests.testPostDepartureUsesHalfDayAndLastFridayDeparture)
]
for (name, run) in checks {
    do { try run(); print("PASS \(name)") }
    catch { failure("\(name): \(error)", file: #filePath, line: #line) }
}
print("\(checks.count) checks passed")

let countdownSamples: [(CountdownDisplay, String, String)] = [
    (.milliseconds, "3661250밀리초", "3661250 ms"),
    (.seconds, "3662초", "3662 sec"),
    (.minutes, "62분", "62 min"),
    (.hours, "1.1시간", "1.1 hr"),
    (.hoursMinutes, "1시간 2분", "1 hr 2 min")
]
for (choice, korean, english) in countdownSamples {
    expectEqual(choice.text(seconds: 3661.25, korean: true), korean)
    expectEqual(choice.text(seconds: 3661.25, korean: false), english)
    let positivePrefix = choice == .milliseconds ? "250" : choice == .hours ? "0.1" : "1"
    expectTrue(choice.text(seconds: 0.25, korean: false).hasPrefix(positivePrefix))
    expectTrue(choice.text(seconds: -1, korean: false).hasPrefix("0"))
    expectTrue(choice.text(seconds: 0, korean: false).hasPrefix("0"))
}
expectEqual(CountdownDisplay.hoursMinutes.text(seconds: 3600, korean: false), "1 hr")
expectEqual(CountdownDisplay.hours.text(seconds: 3600, korean: false), "1 hr")
expectEqual(CountdownDisplay.minutes.text(seconds: 60, korean: false), "1 min")
print("PASS countdown formats: five units, two languages, fractional/boundary/expired durations")


let decimalHourSamples: [(TimeInterval, String)] = [
    (5400, "1.5"), (1800, "0.5"), (0, "0"), (-1, "0"),
    (0.001, "0.1"), (359.999, "0.1"), (360, "0.1"), (360.001, "0.2"),
    (3599.999, "1"), (3600, "1"), (3600.001, "1.1"),
    (5399.999, "1.5"), (5400.001, "1.6"), (72_000, "20"), (72_001, "20"),
    (.infinity, "0"), (-.infinity, "0"), (.nan, "0")
]
for (seconds, number) in decimalHourSamples {
    expectEqual(CountdownDisplay.hours.text(seconds: seconds, korean: true), number + "시간")
    expectEqual(CountdownDisplay.hours.text(seconds: seconds, korean: false), number + " hr")
}
expectEqual(CountdownDisplay.hours.refreshInterval, 1)
expectEqual(CountdownDisplay.milliseconds.refreshInterval, 0.1)
print("PASS decimal hours: requested examples, tenth/integer boundaries, positive/expired/nonfinite durations, Korean/English")

let preferenceSuite = "HappyLuluChecks.countdown." + UUID().uuidString
let testDefaults = UserDefaults(suiteName: preferenceSuite)!
defer { testDefaults.removePersistentDomain(forName: preferenceSuite) }
expectEqual(CountdownDisplay.saved(in: testDefaults), .hoursMinutes)
for choice in CountdownDisplay.allCases {
    choice.save(in: testDefaults)
    let restartedDefaults = UserDefaults(suiteName: preferenceSuite)!
    expectEqual(CountdownDisplay.saved(in: restartedDefaults), choice)
    expectEqual(restartedDefaults.string(forKey: "HappyLuluCountdownDisplay"), choice.rawValue)
}
testDefaults.set("unknown-unit", forKey: "HappyLuluCountdownDisplay")
expectEqual(CountdownDisplay.saved(in: testDefaults), .hoursMinutes)
print("PASS saved countdown units: existing key, every selection after reload, absent/unknown fallback; isolated test suite")

try checkLoginLaunch()

// Settings use whole minutes; protect the shared hours/minutes presentation.
let settingsDurationSamples: [(Int, String, String)] = [
    (0, "0분", "0 min"), (1, "1분", "1 min"), (59, "59분", "59 min"),
    (60, "1시간", "1 hr"), (61, "1시간 1분", "1 hr 1 min"),
    (240, "4시간", "4 hr"), (480, "8시간", "8 hr"), (960, "16시간", "16 hr")
]
for (minutes, korean, english) in settingsDurationSamples {
    expectEqual(CountdownDisplay.hoursMinutes.text(seconds: TimeInterval(minutes) * 60, korean: true), korean)
    expectEqual(CountdownDisplay.hoursMinutes.text(seconds: TimeInterval(minutes) * 60, korean: false), english)
}
print("PASS settings durations: zero, hour boundaries, valid work/break limits, Korean/English")
