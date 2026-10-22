import XCTest
@testable import AIUsagePlugin

final class UsageHistoryTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 2_000_000_000)

    private func sample(minutes: Double, used: Double, account: String? = "account-a", reset: Double = 2_001_000_000) -> UsageSnapshot {
        UsageSnapshot(weekly: UsageWindow(usedPercent: used, windowDurationMins: 10080, resetsAt: reset),
                      fetchedAt: origin.addingTimeInterval(minutes * 60), accountKey: account)
    }

    func testNoDataAndOneSampleAreUnknown() {
        var history = UsageHistory()
        XCTAssertNil(history.analysis(at: origin).hour)
        history.record(sample(minutes: 0, used: 20), cadenceMinutes: 5)
        let analysis = history.analysis(at: origin)
        XCTAssertNil(analysis.hour)
    }

    func testFractionalRatesUseUnroundedUsageAndActualElapsedTime() {
        var history = UsageHistory()
        history.record(sample(minutes: 0, used: 20.1), cadenceMinutes: 5)
        history.record(sample(minutes: 5, used: 20.2), cadenceMinutes: 5)
        let analysis = history.analysis(at: origin.addingTimeInterval(300))
        XCTAssertEqual(analysis.hour!.perHour, 1.2, accuracy: 0.000001)
        XCTAssertEqual(analysis.hour!.observedMinutes, 5)
    }

    func testHourlyRateUsesFullObservedHour() {
        var history = UsageHistory()
        for minute in stride(from: 0, through: 55, by: 5) {
            history.record(sample(minutes: Double(minute), used: 20), cadenceMinutes: 5)
        }
        history.record(sample(minutes: 60, used: 21), cadenceMinutes: 5)
        let analysis = history.analysis(at: origin.addingTimeInterval(3600))
        XCTAssertEqual(analysis.hour!.perHour, 1, accuracy: 0.000001)
        XCTAssertEqual(analysis.hour!.observedMinutes, 60)
    }

    func testHourlyRateExcludesOlderConsumption() {
        var history = UsageHistory()
        for minute in stride(from: 0, through: 70, by: 5) {
            history.record(sample(minutes: Double(minute), used: minute < 10 ? 10 : 20), cadenceMinutes: 5)
        }
        let analysis = history.analysis(at: origin.addingTimeInterval(70 * 60))
        XCTAssertEqual(analysis.hour!.perHour, 0)
        XCTAssertEqual(analysis.hour!.observedMinutes, 60)
    }

    func testFastManualRefreshesDoNotInventSubMinuteRates() {
        var history = UsageHistory()
        history.record(sample(minutes: 0, used: 20), cadenceMinutes: 5)
        history.record(sample(minutes: 0.1, used: 21), cadenceMinutes: 5)
        XCTAssertNil(history.analysis(at: origin.addingTimeInterval(6)).hour)
        history.record(sample(minutes: 1, used: 21), cadenceMinutes: 5)
        XCTAssertEqual(history.analysis(at: origin.addingTimeInterval(60)).hour!.perHour, 60)
    }

    func testIdleObservedUsageIsZeroNotUnknown() {
        var history = UsageHistory()
        history.record(sample(minutes: 0, used: 20), cadenceMinutes: 5)
        history.record(sample(minutes: 5, used: 20), cadenceMinutes: 5)
        XCTAssertEqual(history.analysis(at: origin.addingTimeInterval(300)).hour!.perHour, 0)
    }

    func testResetAccountChangeAndCorrectionsStartNewSeries() {
        for next in [sample(minutes: 5, used: 22, account: "account-b"),
                     sample(minutes: 5, used: 22, reset: 2_002_000_000),
                     sample(minutes: 5, used: 19)] {
            var history = UsageHistory()
            history.record(sample(minutes: 0, used: 20), cadenceMinutes: 5)
            history.record(next, cadenceMinutes: 5)
            XCTAssertEqual(history.sampleCount, 1)
            XCTAssertNil(history.analysis(at: next.fetchedAt).hour)
        }
    }

    func testLongGapAndReversedClockDoNotProduceMisleadingRates() {
        var history = UsageHistory()
        history.record(sample(minutes: 0, used: 20), cadenceMinutes: 5)
        history.record(sample(minutes: 30, used: 40), cadenceMinutes: 5)
        XCTAssertEqual(history.sampleCount, 1)
        XCTAssertNil(history.analysis(at: origin.addingTimeInterval(1800)).hour)
        history.record(sample(minutes: 20, used: 25), cadenceMinutes: 5)
        XCTAssertEqual(history.sampleCount, 1)
        XCTAssertNil(history.analysis(at: origin.addingTimeInterval(1200)).hour)
    }

    func testThirtyMinuteCadenceIsSupported() {
        var history = UsageHistory()
        history.record(sample(minutes: 0, used: 20), cadenceMinutes: 30)
        history.record(sample(minutes: 30, used: 21), cadenceMinutes: 30)
        let analysis = history.analysis(at: origin.addingTimeInterval(1800))
        XCTAssertEqual(analysis.hour!.perHour, 2)
        XCTAssertEqual(analysis.hour!.observedMinutes, 30)
    }

    func testHistorySurvivesRelaunchWithoutMixingAccounts() throws {
        var history = UsageHistory()
        history.record(sample(minutes: 0, used: 20), cadenceMinutes: 5)
        history.record(sample(minutes: 5, used: 21), cadenceMinutes: 5)
        let data = try JSONEncoder().encode(history)
        var restored = try JSONDecoder().decode(UsageHistory.self, from: data)
        restored.record(sample(minutes: 10, used: 22), cadenceMinutes: 5)
        XCTAssertEqual(restored.analysis(at: origin.addingTimeInterval(600)).hour!.perHour, 12)
        restored.record(sample(minutes: 15, used: 30, account: "account-b"), cadenceMinutes: 5)
        XCTAssertNil(restored.analysis(at: origin.addingTimeInterval(900)).hour)
    }

    func testExpiredQuotaAndMissingResetSuppressAnalysis() {
        var history = UsageHistory()
        history.record(sample(minutes: 0, used: 20, reset: origin.timeIntervalSince1970 + 600), cadenceMinutes: 5)
        history.record(sample(minutes: 5, used: 21, reset: origin.timeIntervalSince1970 + 600), cadenceMinutes: 5)
        XCTAssertNil(history.analysis(at: origin.addingTimeInterval(600)).hour)
        history.record(UsageSnapshot(weekly: UsageWindow(usedPercent: 21, windowDurationMins: 10080, resetsAt: nil)),
                       cadenceMinutes: 5)
        XCTAssertEqual(history.sampleCount, 0)
    }

    func testMissingAccountIdentityIsNotPersisted() {
        var history = UsageHistory()
        history.record(sample(minutes: 0, used: 20, account: nil), cadenceMinutes: 5)
        history.record(sample(minutes: 5, used: 21, account: nil), cadenceMinutes: 5)
        XCTAssertFalse(history.canPersist)
        XCTAssertNotNil(history.analysis(at: origin.addingTimeInterval(300)).hour)
    }

    func testCorruptStoredSeriesIsRejected() throws {
        let json = #"{"accountKey":"test","resetsAt":3000000000,"samples":[{"date":1000,"usedPercent":20,"cadenceMinutes":5},{"date":1300,"usedPercent":10,"cadenceMinutes":5}]}"#
        let history = try JSONDecoder().decode(UsageHistory.self, from: Data(json.utf8))
        XCTAssertEqual(history.sampleCount, 0)
    }
}
