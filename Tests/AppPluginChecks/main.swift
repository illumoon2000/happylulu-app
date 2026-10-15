import Foundation
import AppPluginCore
import DaouOfficePlugin

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

// These checks exercise the plugin contract without a company account or the user's Keychain.
@MainActor
final class FixturePlugin: AppPlugin {
    let descriptor = PluginDescriptor(id: "fixture", name: "Fixture")
    var continuation: CheckedContinuation<PluginSnapshot, Error>?
    func refresh() async throws -> PluginSnapshot {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func cancel() { continuation?.resume(throwing: CancellationError()); continuation = nil }
}

@MainActor
func checkRegistry() async throws {
    let registry = PluginRegistry()
    let fixture = FixturePlugin()
    try registry.register(fixture)
    do { try registry.register(fixture); fatalError("Duplicate plugin accepted") }
    catch PluginFailure.duplicatePlugin {}
    try registry.activate("fixture")
    let task = Task { try await registry.refresh("fixture") }
    while fixture.continuation == nil { await Task.yield() }
    registry.deactivate("fixture")
    do { _ = try await task.value; fatalError("Disabled refresh was published") }
    catch is CancellationError {}
    require(registry.snapshot(for: "fixture") == nil, "Disabled plugin data leaked")
    try registry.activate("fixture")
    let success = Task { try await registry.refresh("fixture") }
    while fixture.continuation == nil { await Task.yield() }
    fixture.continuation?.resume(returning: PluginSnapshot(pluginID: "fixture", fetchedAt: Date(), leave: nil, vacations: [], events: [], coverage: PluginCoverage()))
    fixture.continuation = nil
    _ = try await success.value
    require(registry.snapshot(for: "fixture") != nil, "Snapshot unavailable to internal consumers")
    print("PASS plugin registry: duplicate IDs, cancellation, disabled data and internal API")
}

func checkAddress() throws {
    let config = try DaouOfficeConfiguration(enabled: true, address: "https://example.daouoffice.com/", loginID: " employee ")
    require(config.loginID == "employee", "ID whitespace not normalized")
    require(config.baseURL.absoluteString == "https://example.daouoffice.com/", "Company origin changed")
    for address in ["http://example.com", "https://user:secret@example.com", "https://example.com/?password=x", "https://example.com/#x", "file:///tmp/account", "https://example.com/arbitrary"] {
        do { _ = try DaouOfficeConfiguration(enabled: true, address: address, loginID: "employee"); fatalError("Unsafe company address accepted") }
        catch PluginFailure.invalidAddress {}
    }
    require(config.allows(URL(string: "https://example.daouoffice.com/ehr/app/leave/my-leave-status")!), "Same-origin page rejected")
    require(!config.allows(URL(string: "https://example.daouoffice.com.evil.invalid/login")!), "Origin suffix accepted")
    require(!config.allows(URL(string: "https://example.daouoffice.com:444/login")!), "Different port accepted")
    print("PASS company URL: HTTPS, no embedded secrets and exact origin")
}

func checkParser() throws {
    let balance = try DaouOfficeAPIParser.balance(Data(#"{"data":{"totalDays":7,"usedDays":4.5,"formattedRemain":"2.5d (20h 0m)"}}"#.utf8))
    require(balance.remainingDays == 2.5, "Fractional leave lost")
    let stringBalance = try DaouOfficeAPIParser.balance(Data(#"{"data":{"totalDays":"7","usedDays":"4.5","formattedRemain":"2.5d (20h 0m)"}}"#.utf8))
    require(stringBalance.totalDays == 7 && stringBalance.usedDays == 4.5 && stringBalance.remainingDays == 2.5,
            "The company API's decimal string balance was rejected")
    let compactBalance = try DaouOfficeAPIParser.balance(Data(#"{"data":{"totalDays":"7","usedDays":"4.5","formattedRemain":"2.5d(20h 0m)"}}"#.utf8))
    require(compactBalance.remainingDays == 2.5, "Compact service day/hour formatting was rejected")
    let leaves = try DaouOfficeAPIParser.vacations(Data(#"{"data":{"elements":[{"title":"연차","approvalStatusType":"APPROVAL","formattedUsedDuration":"2d (16h 0m)","dateRangeType":"DATE_SELECTION","dateList":[{"date":"2026-07-10"},{"date":"2026-07-13"}]},{"title":"연차","approvalStatusType":"APPROVAL","formattedUsedDuration":"0.5d (4h 0m)","dateRangeType":"PERIOD_SPECIFICATION","startDate":"2026-04-13","endDate":"2026-04-13"}]}}"#.utf8))
    require(leaves[0].dates == ["2026-07-10", "2026-07-13"], "Weekend fabricated into leave")
    require(leaves[1].kind == "연차" && leaves[1].days == 0.5, "Unobserved half-day type invented")
    require(leaves[1].rangeStart == "2026-04-13", "Explicit period lost")
    let month = DateInterval(start: try DaouOfficeAPIParser.date("2026-10-01T00:00:00+09:00"),
                             end: try DaouOfficeAPIParser.date("2026-11-01T00:00:00+09:00"))
    let events = try DaouOfficeAPIParser.events(Data(#"{"code":"200","data":[{"id":1557658355206787072,"calendarId":1476755976291233792,"summary":"미팅","startTime":"2026-10-12T11:00:00.000+09:00","endTime":"2026-10-12T12:00:00.000+09:00","timeType":"timed"},{"id":1557658355206787072,"calendarId":1476755976291233792,"summary":"미팅","startTime":"2026-10-19T11:00:00.000+09:00","endTime":"2026-10-19T12:00:00.000+09:00","timeType":"timed"},{"id":"200","calendarId":"100","summary":"연차","startTime":"2026-10-15T00:00:00.000+09:00","endTime":"2026-10-15T23:59:59.000+09:00","timeType":"allday"}]}"#.utf8), during: month)
    require(events.count == 3, "Recurring occurrences merged")
    require(events[0].calendarID == "1476755976291233792", "Int64 ID precision lost")
    require(events[1].isAllDay && events[0].end != nil, "Actual event time range lost")
    for invalid in [#"{}"#, #"{"data":{"totalDays":7,"usedDays":4.5}}"#, #"{"data":{"totalDays":true,"usedDays":4.5,"formattedRemain":"2d"}}"#,
                    #"{"data":{"totalDays":"NaN","usedDays":"4.5","formattedRemain":"2d"}}"#,
                    #"{"data":{"totalDays":"7 days","usedDays":"4.5","formattedRemain":"2d"}}"#] {
        do { _ = try DaouOfficeAPIParser.balance(Data(invalid.utf8)); fatalError("Malformed response accepted") }
        catch {}
    }
    do { _ = try DaouOfficeAPIParser.localDay("2026-02-30"); fatalError("Invalid date accepted") } catch {}
    print("PASS API parser: fractional balance, exact days/periods, recurrence, Int64 IDs and strict schema")
}

func checkConfigurationStore() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HappyLulu-plugin-check-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = DaouOfficeConfigurationStore(url: folder.appendingPathComponent("config.json"))
    let initial = try store.load()
    require(initial == nil, "Unconfigured plugin starts enabled")
    let config = try DaouOfficeConfiguration(enabled: true, address: "https://example.daouoffice.com", loginID: "employee")
    try store.save(config)
    let loaded = try store.load()
    require(loaded == config, "Settings did not survive restart")
    let bytes = try Data(contentsOf: store.url)
    require(!String(decoding: bytes, as: UTF8.self).contains("password"), "Secret field persisted with settings")
    try Data(#"{"version":99}"#.utf8).write(to: store.url)
    do { _ = try store.load(); fatalError("Future configuration silently reset") }
    catch PluginFailure.configuration {}
    let preserved = try Data(contentsOf: store.url)
    require(preserved == Data(#"{"version":99}"#.utf8), "Unreadable configuration modified")
    print("PASS configuration: opt-in default, restart, no password metadata and corruption preservation")
}

checkDailyAgenda()
try checkAddress()
try checkParser()
try await checkAllDayMonthBoundary()
try checkConfigurationStore()
try await checkRegistry()
try await checkFeatureAdapters()
try await checkAPIClient()
try await checkCurlTransport()
