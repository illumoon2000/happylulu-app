import AppKit
import Combine
import AppPluginCore
import AfterSixCore

func require(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }

@MainActor
final class LeaveFixture: FeatureAdapter {
    let descriptor: FeatureAdapterDescriptor
    var calendarTimeZone: TimeZone?
    var snapshot: PluginSnapshot?
    init(_ id: String, timeZone: TimeZone?) {
        descriptor = FeatureAdapterDescriptor(id: id, name: "Synthetic leave", features: [.leave])
        calendarTimeZone = timeZone
    }
    func leaveSnapshot() -> PluginSnapshot? { snapshot }
    func calendarEvents(in interval: DateInterval) async throws -> [FeatureCalendarEvent] { [] }
    func requestHalfDayAccess() async throws {}
    func halfDayTitles(on day: Date, timeZone: TimeZone) async throws -> [String] { [] }
}

@main
struct VacationEveProbe {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = Bundle.main.bundleIdentifier!
        require(suite.hasPrefix("test.happylulu.vacation-eve."), "Probe must use an isolated defaults domain")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        for (zone, deviceZone, date) in [
            ("Asia/Seoul", "UTC", [2026, 12, 31]),
            ("America/Los_Angeles", "America/Los_Angeles", [2026, 3, 7]),
            ("America/Los_Angeles", "America/Los_Angeles", [2026, 10, 31])
        ] {
            var source = Calendar(identifier: .gregorian); source.timeZone = TimeZone(identifier: zone)!
            var device = Calendar(identifier: .gregorian); device.timeZone = TimeZone(identifier: deviceZone)!
            let deviceCalendar = device
            let departure = source.date(from: DateComponents(year: date[0], month: date[1], day: date[2], hour: 18))!
            let arrivalTime = source.date(bySettingHour: 9, minute: 0, second: 0, of: departure)!
            let start = departure.addingTimeInterval(-600)
            var now = start
            let next = source.date(byAdding: .day, value: 1, to: source.startOfDay(for: now))!
            let tomorrow = Attendance.dayKey(next, calendar: source)
            let adapter = LeaveFixture("leave", timeZone: source.timeZone)
            let other = LeaveFixture("other", timeZone: source.timeZone)
            let manager = PluginManagerModel(defaultAdapter: other, routingStore: FeatureRoutingStore(url: nil))
            try manager.router.register(adapter, enabled: true)
            manager.select(adapter.descriptor.id, for: .leave)
            func publish(_ status: String = "APPROVAL", fetchedAt: Date? = nil) {
                adapter.snapshot = PluginSnapshot(pluginID: "leave", fetchedAt: fetchedAt ?? now, leave: nil,
                    vacations: [PluginVacation(id: "synthetic", kind: "연차", status: status, days: 1,
                        dates: [tomorrow], periodLabel: tomorrow)], events: [], coverage: PluginCoverage())
            }
            let day = Attendance.dayKey(now, calendar: device)
            var state = AttendanceState(); state.didOfferLoginItem = true; state.detectHalfDaysFromCalendar = false
            state.arrivals[day] = Arrival(day: day, time: arrivalTime, source: .manual,
                timeZoneID: zone, mode: .normal, modeSource: .manual, earlyLeaveOverrideMinutes: 0)
            let store = StateStore(url: root.appendingPathComponent("fixture-\(zone.replacingOccurrences(of: "/", with: "-"))-\(date[1]).json"))
            try store.save(state)
            let original = try Data(contentsOf: store.url)
            let model = AppModel(store: store, featureRouter: manager.router, allowsLoginItemChanges: false,
                nowProvider: { now }, calendarProvider: { deviceCalendar })
            model.observeFeatures(manager)
            publish()
            require(model.departure == departure, "Fixture must use actual attendance departure")
            require(model.isVacationEve, "Confirmed tomorrow leave must dress owl at exactly departure minus 600 seconds")
            for (offset, expected) in [(-0.001, false), (0.0, true), (0.001, true), (600.0, true), (601.0, true)] {
                now = start.addingTimeInterval(offset); publish(); model.refresh()
                require(model.isVacationEve == expected, "Exact vacation boundary failed: \(zone), \(offset)")
            }
            now = start; publish(); model.refresh()
            let originalDeparture = model.departure
            publish("CANCEL"); require(!model.isVacationEve, "Cancellation must restore normal appearance")
            publish("RETURN"); require(!model.isVacationEve, "Rejected leave must not decorate")
            publish(); require(model.isVacationEve, "Fresh approval must restore preview")
            adapter.snapshot = nil; require(!model.isVacationEve, "Missing snapshot must restore normal appearance")
            publish(fetchedAt: now.addingTimeInterval(-901)); require(!model.isVacationEve, "Expired snapshot must not decorate")
            publish()
            manager.router.setEnabled(false, for: "leave")
            require(!model.isVacationEve, "Disabled source must not decorate")
            manager.router.setEnabled(true, for: "leave"); manager.select("leave", for: .leave)
            require(model.isVacationEve, "Reconnected selected source must use its fresh snapshot")
            // A leave-only routing change must publish even when half-day routing is unchanged.
            for _ in 0..<20 { await Task.yield() }
            var updates = 0
            let observation = model.objectWillChange.sink { _ in updates += 1 }
            manager.select("other", for: .leave)
            for _ in 0..<40 { await Task.yield() }
            require(updates > 0 && !model.isVacationEve, "Leave source changes must notify the displayed character immediately")
            withExtendedLifetime(observation) {}
            manager.select("leave", for: .leave)
            require(model.departure == originalDeparture, "Costume must not change departure")
            require(tryData(store.url) == original, "Costume evaluation must not mutate attendance storage")
            now = next.addingTimeInterval(-0.001); publish(); model.refresh()
            require(model.isVacationEve, "Preview must remain through the previous local day")
            now = next; publish(); model.refresh()
            require(!model.isVacationEve, "Preview must stop at leave-source local midnight")
            now = start; publish(); model.refresh()
            adapter.calendarTimeZone = nil
            require(!model.isVacationEve, "Unknown leave timezone must not guess tomorrow")
            adapter.calendarTimeZone = source.timeZone
            for variant in ["no-arrival", "day-off", "annual-leave", "overnight"] {
                var changed = state
                if variant == "no-arrival" { changed.arrivals = [:] }
                if variant == "day-off" { changed.suppressedDays.insert(day) }
                if variant == "annual-leave" { changed.manualDayTypes[day] = .annualLeave }
                if variant == "overnight" { changed.settings.workMinutes = 960 }
                try store.save(changed)
                let blocked = AppModel(store: store, featureRouter: manager.router, allowsLoginItemChanges: false,
                    nowProvider: { now }, calendarProvider: { deviceCalendar })
                require(!blocked.isVacationEve, "Today \(variant) must take priority over tomorrow's costume")
            }
            // The same rule uses each work mode's actual departure, not a hard-coded 18:00.
            for mode in [WorkdayMode.morningHalf, .afternoonHalf, .normal] {
                var changed = state
                let time = source.date(bySettingHour: mode == .morningHalf ? 13 : 9, minute: 0, second: 0, of: start)!
                changed.arrivals[day] = Arrival(day: day, time: time, source: .manual, timeZoneID: zone,
                    mode: mode, modeSource: .manual, earlyLeaveOverrideMinutes: mode == .normal ? 120 : nil)
                try store.save(changed)
                let work = AppModel(store: store, featureRouter: manager.router, allowsLoginItemChanges: false,
                    nowProvider: { now }, calendarProvider: { deviceCalendar })
                now = work.departure!.addingTimeInterval(-600); publish(); work.refresh()
                require(work.isVacationEve, "Current work mode must use calculated departure")
                now = now.addingTimeInterval(-0.001); publish(); work.refresh()
                require(!work.isVacationEve, "Work mode must preserve exact ten-minute boundary")
            }
        }
        print("PASS vacation-eve integration: exact 600-second boundary, cancellation, data/source changes, freshness, year/DST/local midnight, state priority, work modes and unchanged attendance")
    }
    static func tryData(_ url: URL) -> Data { try! Data(contentsOf: url) }
}
