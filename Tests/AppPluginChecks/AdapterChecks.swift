import Foundation
import AppPluginCore
import DaouOfficePlugin

@MainActor
final class FixtureFeatureAdapter: FeatureAdapter {
    let descriptor: FeatureAdapterDescriptor
    var held: CheckedContinuation<[FeatureCalendarEvent], Error>?
    var pauses = false
    var titles: [String] = []
    init(_ id: String, features: Set<AppFeature> = Set(AppFeature.allCases)) {
        descriptor = FeatureAdapterDescriptor(id: id, name: id, features: features)
    }
    func calendarEvents(in interval: DateInterval) async throws -> [FeatureCalendarEvent] {
        if pauses { return try await withCheckedThrowingContinuation { held = $0 } }
        return []
    }
    func leaveSnapshot() -> PluginSnapshot? { nil }
    func requestHalfDayAccess() async throws {}
    func halfDayTitles(on day: Date, timeZone: TimeZone) async throws -> [String] { titles }
}

@MainActor
final class SnapshotFixturePlugin: AppPlugin {
    let descriptor: PluginDescriptor
    let value: PluginSnapshot
    init(_ value: PluginSnapshot) { self.value = value; descriptor = PluginDescriptor(id: value.pluginID, name: value.pluginID) }
    func refresh() async throws -> PluginSnapshot { value }
    func cancel() {}
}

@MainActor
func checkFeatureAdapters() async throws {
    let start = try DaouOfficeAPIParser.date("2026-10-01T00:00:00+09:00")
    let end = try DaouOfficeAPIParser.date("2026-11-01T00:00:00+09:00")
    let interval = DateInterval(start: start, end: end)
    let builtin = FixtureFeatureAdapter("builtin"), alpha = FixtureFeatureAdapter("alpha")
    let beta = FixtureFeatureAdapter("beta", features: [.leave])
    let router = FeatureAdapterRouter(defaultAdapter: builtin)
    try router.register(alpha, enabled: true); try router.register(beta, enabled: true)
    require(router.descriptors.count == 3, "Multiple adapters were not registered")
    do { try router.register(alpha); fatalError("Duplicate adapter replaced a registered source") }
    catch FeatureAdapterFailure.duplicate {}
    try router.select("alpha", for: .calendar); try router.select("beta", for: .leave)
    require(router.selectedID(for: .halfDay) == "builtin", "One feature selection silently changed attendance's source")
    do { try router.select("beta", for: .calendar); fatalError("Unsupported feature accepted") }
    catch FeatureAdapterFailure.unsupported {}
    alpha.pauses = true
    let pending = Task { try await router.calendarEvents(in: interval) }
    while alpha.held == nil { await Task.yield() }
    router.setEnabled(false, for: "alpha")
    alpha.held?.resume(returning: []); alpha.held = nil
    do { _ = try await pending.value; fatalError("Disabled adapter's in-flight result was published") }
    catch is CancellationError {}
    require(router.selectedID(for: .calendar) == "builtin" && router.selectedID(for: .leave) == "beta", "Disable changed unrelated feature routing")
    do { try router.select("alpha", for: .halfDay); fatalError("Disabled adapter selected") }
    catch FeatureAdapterFailure.unavailable {}
    router.setEnabled(true, for: "alpha"); try router.select("alpha", for: .calendar)
    let independent = Task { try await router.calendarEvents(in: interval) }
    while alpha.held == nil { await Task.yield() }
    try router.select("builtin", for: .leave)
    alpha.held?.resume(returning: []); alpha.held = nil
    _ = try await independent.value
    router.unregister("beta"); router.unregister("builtin")
    require(router.selectedID(for: .leave) == "builtin" && router.isEnabled("builtin"), "Default adapter could be removed or disabled")

    let holiday = try DaouOfficeAPIParser.date("2026-10-03T00:00:00+09:00")
    let old = try DaouOfficeAPIParser.date("1970-02-06T00:00:00+09:00")
    let registry = PluginRegistry()
    let snapshot = PluginSnapshot(pluginID: "alpha", fetchedAt: start, leave: PluginLeaveBalance(totalDays: 10, usedDays: 3, remainingDays: 7), vacations: [],
        events: [PluginCalendarEvent(id: "1", calendarID: "1", title: "공휴일", start: holiday, end: holiday, isAllDay: true),
                 PluginCalendarEvent(id: "2", calendarID: "1", title: "기준일", start: old, end: old, isAllDay: true)],
        coverage: PluginCoverage(calendarFrom: "2026-10-01", calendarThrough: "2026-10-31"))
    try registry.register(SnapshotFixturePlugin(snapshot)); try registry.activate("alpha"); _ = try await registry.refresh("alpha")
    let adapter = SnapshotFeatureAdapter(descriptor: alpha.descriptor, api: registry,
        timeZone: TimeZone(identifier: "Asia/Seoul")!, inclusiveAllDayEnd: true)
    let values = try await adapter.calendarEvents(in: interval)
    require(values.count == 1 && values[0].start == holiday && values[0].end.timeIntervalSince(holiday) == 86400,
        "All-day holiday normalization or reference date filtering failed")
    require(adapter.leaveSnapshot()?.leave?.remainingDays == 7, "Leave binding lost the source snapshot")
    let titles = try await adapter.halfDayTitles(on: holiday, timeZone: TimeZone(identifier: "Asia/Seoul")!)
    require(titles == ["공휴일"], "Half-day adapter read unrelated dates")
    let companyRouter = FeatureAdapterRouter(defaultAdapter: builtin)
    try companyRouter.register(adapter, enabled: true); try companyRouter.select("alpha", for: .halfDay)
    let monthEnd = try DaouOfficeAPIParser.date("2026-10-31T12:00:00Z")
    _ = try await companyRouter.halfDayTitles(on: monthEnd, timeZone: TimeZone(secondsFromGMT: 0)!)
    do { _ = try await adapter.calendarEvents(in: DateInterval(start: old, end: start)); fatalError("Unavailable historical coverage shown as an empty successful read") }
    catch FeatureAdapterFailure.outsideCoverage {}
    registry.deactivate("alpha")
    do { _ = try await adapter.calendarEvents(in: interval); fatalError("Disabled snapshot reached a bound feature") }
    catch FeatureAdapterFailure.missingSnapshot {}
    print("PASS feature adapters: multiple sources, capabilities, independent routing, default fallback, stale results, coverage, leave and all-day events")
}

@MainActor
func checkAllDayMonthBoundary() async throws {
    let first = try DaouOfficeAPIParser.date("2026-10-01T00:00:00+09:00")
    let month = DateInterval(start: first, end: try DaouOfficeAPIParser.date("2026-11-01T00:00:00+09:00"))
    func event(_ id: Int, _ title: String, _ start: String, _ end: String, type: String = "allday") -> [String: String] {
        ["id": String(id), "calendarId": "1", "summary": title, "startTime": start, "endTime": end, "timeType": type]
    }
    let input = try JSONSerialization.data(withJSONObject: ["data": [
        event(1, "spanning", "2026-09-30T00:00:00+09:00", "2026-10-01T00:00:00+09:00"),
        event(2, "timed-before", "2026-09-30T22:00:00+09:00", "2026-10-01T00:00:00+09:00", type: "timed"),
        event(3, "allday-before", "2026-09-30T00:00:00+09:00", "2026-09-30T00:00:00+09:00"),
        event(4, "holiday", "2026-10-03T00:00:00+09:00", "2026-10-03T00:00:00+09:00"),
        event(5, "after", "2026-11-01T00:00:00+09:00", "2026-11-01T00:00:00+09:00"),
        event(6, "reference", "1970-02-06T00:00:00+09:00", "1970-02-06T00:00:00+09:00")
    ]])
    let events = try DaouOfficeAPIParser.events(input, during: month)
    require(events.count == 2 && Set(events.map(\.title)) == ["spanning", "holiday"],
        "Parser lost the inclusive all-day month boundary or included out-of-range events")
    require(events.first(where: { $0.title == "spanning" })?.end == first,
        "Parser changed the original inclusive end, causing the adapter to add an extra day")
    let registry = PluginRegistry()
    let snapshot = PluginSnapshot(pluginID: "fixture", fetchedAt: first, leave: nil, vacations: [], events: events,
        coverage: PluginCoverage(calendarFrom: "2026-10-01", calendarThrough: "2026-10-31"))
    try registry.register(SnapshotFixturePlugin(snapshot)); try registry.activate("fixture"); _ = try await registry.refresh("fixture")
    let adapter = SnapshotFeatureAdapter(descriptor: FeatureAdapterDescriptor(id: "fixture", name: "Fixture", features: [.calendar, .halfDay]),
        api: registry, timeZone: TimeZone(identifier: "Asia/Seoul")!, inclusiveAllDayEnd: true)
    let displayed = try await adapter.calendarEvents(in: month)
    let dayAfter = try DaouOfficeAPIParser.date("2026-10-02T00:00:00+09:00")
    require(displayed.count == 2 && displayed.first(where: { $0.title == "spanning" })?.end == dayAfter,
        "Parser-to-adapter month boundary was lost or all-day end was normalized twice")
    let titles = try await adapter.halfDayTitles(on: first, timeZone: TimeZone(identifier: "Asia/Seoul")!)
    require(titles == ["spanning"], "Month-boundary event did not reach the day-specific feature")
    print("PASS all-day month boundary: inclusive overlap, exclusive timed ends, reference filtering and parser-to-adapter bounds")
}
