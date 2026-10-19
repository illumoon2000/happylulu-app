import AppKit
import SwiftUI
import Combine
import AppPluginCore
import AppPluginHost
import AfterSixCore
import CalendarSyncServices

func fixtureDate(_ value: String) throws -> Date {
    guard let date = ISO8601DateFormatter().date(from: value) else { throw FeatureAdapterFailure.unsupported }
    return date
}

func require(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }

@MainActor
final class ProbeController: ObservableObject, PluginController {
    let descriptor: PluginDescriptor
    @Published var enabled = true
    @Published var sessionRevision = 0
    var starts = 0, stops = 0, refreshes = 0
    var changes: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
    var isRunning: Bool { false }
    var connectionState: PluginConnectionState { enabled ? .ready : .off }
    init(_ id: String) { descriptor = PluginDescriptor(id: id, name: id) }
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func refreshData() { refreshes += 1 }
}

@MainActor
final class ProbeAdapter: FeatureAdapter {
    let descriptor: FeatureAdapterDescriptor
    var events: [FeatureCalendarEvent] = []
    var titles: [String] = []
    var accessFailure: Error?
    var pausesAccess = false
    var heldAccess: CheckedContinuation<Void, Error>?
    var held: CheckedContinuation<[FeatureCalendarEvent], Error>?
    var pauses = false
    var pausesHalfDays = false
    var heldHalfDay: CheckedContinuation<[String], Error>?
    var halfDayReads: [Date] = []
    var halfDayReplies = 0
    init(_ id: String) { descriptor = FeatureAdapterDescriptor(id: id, name: id, features: Set(AppFeature.allCases)) }
    func calendarEvents(in interval: DateInterval) async throws -> [FeatureCalendarEvent] {
        if pauses { return try await withCheckedThrowingContinuation { held = $0 } }
        return events
    }
    func leaveSnapshot() -> PluginSnapshot? { nil }
    func requestHalfDayAccess() async throws {
        if pausesAccess { try await withCheckedThrowingContinuation { heldAccess = $0 } }
        if let accessFailure { throw accessFailure }
    }
    func halfDayTitles(on day: Date, timeZone: TimeZone) async throws -> [String] {
        halfDayReads.append(day)
        defer { halfDayReplies += 1 }
        if pausesHalfDays { return try await withCheckedThrowingContinuation { heldHalfDay = $0 } }
        return titles
    }
}

@MainActor
final class ProbeDataPlugin: AppPlugin {
    let descriptor: PluginDescriptor
    init(_ id: String) { descriptor = PluginDescriptor(id: id, name: id) }
    var value: PluginSnapshot?
    var failure: PluginFailure?
    func refresh() async throws -> PluginSnapshot {
        if let failure { throw failure }
        guard let value else { throw PluginFailure.unavailable }
        return value
    }
    func cancel() {}
}

@MainActor
enum FailingModule: PluginModule {
    static let id = "failed-fixture"
    static var controller: ProbeController?
    static var calls = 0
    static var failureStage = 2
    static func register(in context: PluginHostContext) throws {
        calls += 1
        controller = nil
        try context.registry.register(ProbeDataPlugin(id))
        if failureStage == 0 { throw PluginFailure.configuration }
        let controller = ProbeController(id)
        self.controller = controller
        try context.register(PluginRegistration(controller: controller, adapter: ProbeAdapter(id),
            symbol: "calendar", summary: "Fixture"))
        if failureStage == 1 { throw PluginFailure.configuration }
        try context.presentations.register(id) { Text("Fixture settings") }
        throw PluginFailure.configuration
    }
}

@MainActor
private func waitForArchitecture(_ message: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        require(Date() < deadline, message)
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func checkMenuCountdownDisplay(root: URL) throws {
    let defaults = UserDefaults.standard
    let departureKey = "HappyLuluShowDepartureInMenuBar"
    let preservedPreferenceKey = "HappyLuluMenuVisibilityProbeUnrelatedPreference"
    let keys = ["HappyLuluCountdownDisplay", departureKey, AppLanguage.key, preservedPreferenceKey]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
        for (key, value) in zip(keys, saved) {
            if let value { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
    let preservedPreference = Data("fixture appearance and updater settings".utf8)
    defaults.set(preservedPreference, forKey: preservedPreferenceKey)
    defaults.removeObject(forKey: departureKey)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    let fixtureCalendar = calendar
    var fixtureNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16,
                                                       hour: 16, minute: 29, second: 30))!
    let arrivalTime = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: fixtureNow)!
    let day = Attendance.dayKey(fixtureNow, calendar: calendar)
    var state = AttendanceState(); state.didOfferLoginItem = true; state.detectHalfDaysFromCalendar = false
    state.arrivals[day] = Arrival(day: day, time: arrivalTime, source: .manual,
        timeZoneID: calendar.timeZone.identifier, mode: .normal, modeSource: .manual, earlyLeaveOverrideMinutes: 0)
    let store = StateStore(url: root.appendingPathComponent("menu-countdown.json"))
    try store.save(state)
    let original = try Data(contentsOf: store.url)
    let routingURL = root.appendingPathComponent("menu-feature-routing.json")
    let originalRouting = Data(#"{"calendar":"builtin","leave":"builtin","halfDay":"builtin"}"#.utf8)
    try originalRouting.write(to: routingURL)
    let manager = PluginManagerModel(defaultAdapter: ProbeAdapter("builtin"), routingStore: FeatureRoutingStore(url: routingURL))
    func makeModel() -> AppModel {
        AppModel(store: store, featureRouter: manager.router, allowsLoginItemChanges: false,
                 nowProvider: { fixtureNow }, calendarProvider: { fixtureCalendar })
    }
    let model = makeModel()
    require(model.showDepartureInMenuBar, "Existing users without the new preference must keep the departure clock")
    var displayChanges = 0
    let observation = model.objectWillChange.sink { _ in displayChanges += 1 }
    let samples: [(CountdownDisplay, String, String)] = [
        (.milliseconds, "5430000밀리초", "5430000 ms"),
        (.seconds, "5430초", "5430 sec"),
        (.minutes, "91분", "91 min"),
        (.hours, "1.6시간", "1.6 hr"),
        (.hoursMinutes, "1시간 31분", "1 hr 31 min")
    ]
    for language in [LanguageChoice.korean, .english] {
        defaults.set(language.rawValue, forKey: AppLanguage.key)
        for (choice, korean, english) in samples {
            model.setCountdownDisplay(choice)
            let remaining = language == .korean ? korean : english
            let expected = language == .korean ? "퇴근 18:00 · \(remaining) 남음" : "Leave 18:00 · \(remaining) left"
            require(model.countdownText == remaining, "Work settings must use the selected countdown unit")
            require(model.menuTitle == expected,
                    "Menu title must reflect \(choice.rawValue) immediately [\(language.rawValue)]: \(model.menuTitle)")
            let restarted = makeModel()
            require(restarted.countdownDisplay == choice && restarted.menuTitle == expected,
                    "Menu countdown choice must survive model reload")
            defaults.set(false, forKey: departureKey)
            let hidden = makeModel()
            let remainingOnly = language == .korean ? "\(remaining) 남음" : "\(remaining) left"
            require(hidden.menuTitle == remainingOnly && hidden.countdownDisplay == choice,
                    "Hidden departure preference must survive reload and preserve the countdown: \(hidden.menuTitle)")
            let changesBeforeToggle = displayChanges
            model.setShowDepartureInMenuBar(false)
            require(displayChanges > changesBeforeToggle && model.menuTitle == remainingOnly,
                    "Hiding the departure must publish an immediate menu update")
            require(!defaults.bool(forKey: departureKey) && !makeModel().showDepartureInMenuBar,
                    "The off selection must persist across model restart")
            require(model.countdownDisplay == choice && model.countdownText == remaining && CountdownDisplay.saved() == choice,
                    "Hiding the clock must preserve the selected countdown unit and work-panel text")
            let changesBeforeRestore = displayChanges
            model.setShowDepartureInMenuBar(true)
            require(displayChanges > changesBeforeRestore && model.menuTitle == expected,
                    "Showing the departure must publish an immediate menu update")
            require(defaults.bool(forKey: departureKey) && makeModel().menuTitle == expected,
                    "The on selection and countdown unit must persist across model restart")
        }
    }
    defaults.set(LanguageChoice.english.rawValue, forKey: AppLanguage.key)
    model.setCountdownDisplay(.seconds)
    fixtureNow = fixtureNow.addingTimeInterval(1)
    model.refresh()
    require(model.menuTitle == "Leave 18:00 · 5429 sec left", "Menu countdown must advance with the model clock")
    model.setShowDepartureInMenuBar(false)
    fixtureNow = fixtureNow.addingTimeInterval(1)
    model.refresh()
    require(model.menuTitle == "5428 sec left", "Countdown must keep advancing while the departure is hidden")
    model.setCountdownDisplay(.milliseconds)
    fixtureNow = fixtureNow.addingTimeInterval(0.25)
    model.refresh()
    require(model.menuTitle == "5427750 ms left", "Hidden departure must preserve subsecond countdown updates")
    fixtureNow = model.departure!
    model.refresh()
    require(model.menuTitle == "Ready to leave", "At departure, hidden clock must leave a meaningful status without zero countdown")
    defaults.set(LanguageChoice.korean.rawValue, forKey: AppLanguage.key)
    require(model.menuTitle == "퇴근 가능", "Hidden departure completion status must support Korean")
    defaults.set(LanguageChoice.english.rawValue, forKey: AppLanguage.key)
    model.setShowDepartureInMenuBar(true)
    require(model.menuTitle == "Leave 18:00", "At departure, preserve the clock without a zero countdown")
    fixtureNow = fixtureNow.addingTimeInterval(60)
    model.refresh()
    require(model.menuTitle == "Leave 18:00", "After departure, preserve the clock without a negative countdown")
    model.setShowDepartureInMenuBar(false)
    require(model.menuTitle == "Ready to leave", "After departure, hidden clock must not return or show a negative countdown")
    let unchanged = try Data(contentsOf: store.url)
    require(unchanged == original, "Countdown display changes must not mutate attendance")
    let unchangedRouting = try Data(contentsOf: routingURL)
    require(unchangedRouting == originalRouting, "Menu visibility changes must preserve feature routing bytes")
    require(defaults.data(forKey: preservedPreferenceKey) == preservedPreference,
            "Menu visibility changes must preserve unrelated preference bytes")
    require(model.setDayType(.annualLeave) && model.menuTitle == "Leave day", "Leave day must not show a countdown")
    model.skipToday()
    require(model.menuTitle == "Day off today", "Skipped day must not show a countdown")
    let emptyModel = AppModel(store: StateStore(url: root.appendingPathComponent("menu-waiting.json")),
        featureRouter: manager.router, allowsLoginItemChanges: false,
        nowProvider: { fixtureNow }, calendarProvider: { fixtureCalendar })
    require(emptyModel.menuTitle == "Waiting for arrival", "Missing arrival must not show a countdown")
    withExtendedLifetime(observation) {}
    print("PASS menu countdown/clock visibility: default-on, five units, Korean/English, off/on persistence and immediate publication, reload, hidden seconds/subseconds, departure boundary, leave/skip/waiting, attendance/routing/unrelated preference byte preservation")
}

@MainActor
private func checkInjectedAttendanceClock(root: URL) throws {
    let defaults = UserDefaults.standard
    let savedCountdown = defaults.object(forKey: "HappyLuluCountdownDisplay")
    defer {
        if let savedCountdown { defaults.set(savedCountdown, forKey: "HappyLuluCountdownDisplay") }
        else { defaults.removeObject(forKey: "HappyLuluCountdownDisplay") }
    }
    for zone in ["UTC", "Asia/Seoul", "America/Los_Angeles"] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        var fixtureCalendar = calendar
        var fixtureNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 8, minute: 11))!
        let store = StateStore(url: root.appendingPathComponent("clock-\(zone)/state.json"))
        let manager = PluginManagerModel(defaultAdapter: ProbeAdapter("builtin"), routingStore: FeatureRoutingStore(url: nil))
        let model = AppModel(store: store, featureRouter: manager.router, allowsLoginItemChanges: false,
                             nowProvider: { fixtureNow }, calendarProvider: { fixtureCalendar })
        let day = "2026-10-16"
        require(model.now == fixtureNow && model.dayKey(model.now) == day && model.calendar.timeZone == calendar.timeZone,
                "Initial attendance clock/calendar ignored the injected local weekday [\(zone)]")
        require(model.saveManualClockText("08:11", forDay: day), "08:11 current-minute arrival must save [\(zone)]")
        let original = try Data(contentsOf: store.url)
        require(!model.saveManualClockText("08:12", forDay: day), "08:12 must remain future at 08:11 [\(zone)]")
        let rejected = try Data(contentsOf: store.url)
        require(rejected == original, "A rejected future arrival changed stored bytes [\(zone)]")
        fixtureNow = fixtureNow.addingTimeInterval(60)
        require(model.saveManualClock(fixtureNow, forDay: day, selectedMode: nil) && model.arrival?.time == fixtureNow,
                "Date-based clock save did not use the advanced injected clock [\(zone)]")
        fixtureNow = calendar.date(bySettingHour: 16, minute: 0, second: 0, of: fixtureNow)!
        let manualTime = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: fixtureNow)!
        require(model.saveManual(manualTime, selectedMode: nil) && model.now == fixtureNow && model.arrival?.time == manualTime,
                "Manual arrival save escaped the injected clock [\(zone)]")
        fixtureNow = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: fixtureNow)!
        model.setCountdownDisplay(model.countdownDisplay)
        require(model.now == fixtureNow && model.dayKey(model.now) == day,
                "Countdown preference refresh escaped the injected clock [\(zone)]")
        let beforeMidnight = try Data(contentsOf: store.url)
        fixtureNow = fixtureNow.addingTimeInterval(1)
        model.refresh()
        require(model.now == fixtureNow && model.dayKey(model.now) == "2026-10-17" && model.arrival == nil,
                "Local midnight refresh retained the previous attendance day [\(zone)]")
        require(!model.saveManualClockText("08:12", forDay: day), "Midnight must reject a previous-day editor [\(zone)]")
        let afterMidnight = try Data(contentsOf: store.url)
        require(afterMidnight == beforeMidnight && model.state.arrivals[day]?.time == manualTime,
                "Stale midnight editor changed preserved attendance [\(zone)]")
        fixtureCalendar.timeZone = TimeZone(identifier: zone == "UTC" ? "Asia/Seoul" : "UTC")!
        require(model.calendar.timeZone == fixtureCalendar.timeZone,
                "Calendar provider was captured once instead of read dynamically [\(zone)]")
    }
    print("PASS injected attendance clock: UTC/Seoul/Los Angeles, 08:11 future guard, advanced minute, manual APIs, countdown refresh, local midnight preservation")
}

@MainActor
private func checkInjectedAsyncClock(root: URL) async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    let fixtureCalendar = calendar
    var fixtureNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 23, minute: 59, second: 59))!
    let checkedAt = fixtureNow
    let store = StateStore(url: root.appendingPathComponent("async-clock.json"))
    var state = AttendanceState(); state.didOfferLoginItem = true; state.detectHalfDaysFromCalendar = true
    try store.save(state)
    let adapter = ProbeAdapter("builtin")
    adapter.pausesHalfDays = true
    let manager = PluginManagerModel(defaultAdapter: adapter, routingStore: FeatureRoutingStore(url: nil))
    let model = AppModel(store: store, featureRouter: manager.router, allowsLoginItemChanges: false,
                         nowProvider: { fixtureNow }, calendarProvider: { fixtureCalendar })
    model.checkCalendarHalfDayNow()
    try await waitForArchitecture("Injected half-day request did not suspend") { adapter.heldHalfDay != nil }
    require(adapter.halfDayReads == [checkedAt], "Async request captured wall time instead of the fixture clock")
    fixtureNow = fixtureNow.addingTimeInterval(1)
    model.refresh()
    let reply = adapter.heldHalfDay!; adapter.heldHalfDay = nil; adapter.pausesHalfDays = false
    reply.resume(returning: ["오후 반차"])
    try await waitForArchitecture("Previous-day half-day reply did not finish") { adapter.halfDayReplies == 1 }
    require(model.calendarHalfDayMode == nil && model.detectedModeToday == nil,
            "Async reply crossed injected local midnight and applied yesterday's mode")
    adapter.titles = ["오전 반차"]
    model.checkCalendarHalfDayNow()
    try await waitForArchitecture("Current-day injected half-day reply was ignored") { model.detectedModeToday == .morningHalf }
    require(adapter.halfDayReads == [checkedAt, fixtureNow] && model.now == fixtureNow,
            "Async refresh did not capture the advanced injected clock")
    print("PASS injected async attendance clock: captured request time, stale reply rejected at local midnight, fresh next-day mode applied")
}

@MainActor
private func checkHalfDaySessionInvalidation(root: URL) async throws {
    let registry = PluginRegistry(), plugin = ProbeDataPlugin("daouoffice-fixture")
    let controller = ProbeController(plugin.descriptor.id)
    let manager = PluginManagerModel(defaultAdapter: ProbeAdapter("builtin"), registry: registry,
        routingStore: FeatureRoutingStore(url: nil))
    let adapter = SnapshotFeatureAdapter(descriptor: FeatureAdapterDescriptor(id: plugin.descriptor.id,
        name: "Fixture", features: Set(AppFeature.allCases)), api: registry, timeZone: Calendar.current.timeZone)
    try registry.register(plugin)
    try manager.register(PluginRegistration(controller: controller, adapter: adapter, symbol: "calendar", summary: "Fixture"))
    manager.select(plugin.descriptor.id, for: .halfDay)
    let now = Date(), calendar = Calendar.current
    let start = calendar.startOfDay(for: now), end = calendar.date(byAdding: .day, value: 1, to: start)!
    let day = Attendance.dayKey(now, calendar: calendar)
    let arrival = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
    plugin.value = PluginSnapshot(pluginID: plugin.descriptor.id, fetchedAt: now, leave: nil, vacations: [],
        events: [PluginCalendarEvent(id: "account-a", calendarID: "fixture", title: "오후 반차", start: start, end: end, isAllDay: true)],
        coverage: PluginCoverage(calendarFrom: day, calendarThrough: day))
    try registry.activate(plugin.descriptor.id)
    try await registry.refresh(plugin.descriptor.id)
    var state = AttendanceState(); state.didOfferLoginItem = true; state.detectHalfDaysFromCalendar = true
    Attendance.recordUnlock(in: &state, at: arrival, calendar: calendar, calendarMode: nil)
    let automaticStore = StateStore(url: root.appendingPathComponent("session-automatic.json"))
    try automaticStore.save(state)
    let automatic = AppModel(store: automaticStore, featureRouter: manager.router)
    try Attendance.setManual(in: &state, at: arrival, now: arrival.addingTimeInterval(60), calendar: calendar,
        selectedMode: .afternoonHalf, calendarMode: nil)
    let manualStore = StateStore(url: root.appendingPathComponent("session-manual.json"))
    try manualStore.save(state)
    let manual = AppModel(store: manualStore, featureRouter: manager.router)
    automatic.observeFeatures(manager); manual.observeFeatures(manager)
    try await waitForArchitecture("Account A half-day was not applied") {
        automatic.detectedModeToday == .afternoonHalf && manual.detectedModeToday == .afternoonHalf
    }
    require(automatic.arrival?.mode == .afternoonHalf, "Account A fixture did not affect automatic attendance")

    // Temporary failure preserves the same account's last successful snapshot and mode.
    plugin.failure = .network
    do { try await registry.refresh(plugin.descriptor.id); fatalError("Expected fixture network failure") }
    catch PluginFailure.network {}
    controller.sessionRevision += 1
    for _ in 0..<20 { await Task.yield() }
    require(automatic.detectedModeToday == .afternoonHalf && automatic.arrival?.mode == .afternoonHalf,
        "A temporary read failure discarded the current account's half-day")

    // Account/session replacement clears registry data while the feature source ID stays selected.
    registry.deactivate(plugin.descriptor.id); try registry.activate(plugin.descriptor.id)
    plugin.failure = .interactionRequired
    do { try await registry.refresh(plugin.descriptor.id); fatalError("Expected fixture CAPTCHA wait") }
    catch PluginFailure.interactionRequired {}
    controller.sessionRevision += 1
    try await waitForArchitecture("Session invalidation did not notify attendance") {
        automatic.calendarHalfDayMessage == FeatureAdapterFailure.missingSnapshot.localizedDescription &&
            manual.calendarHalfDayMessage == FeatureAdapterFailure.missingSnapshot.localizedDescription
    }
    require(manager.router.selectedID(for: .halfDay) == plugin.descriptor.id,
        "Account replacement unexpectedly changed the feature source")
    require(automatic.detectedModeToday == nil && automatic.arrival?.mode == .normal,
        "Same-source account/CAPTCHA replacement retained the previous account's automatic half-day")
    require(manual.detectedModeToday == nil && manual.arrival?.mode == .afternoonHalf && manual.arrival?.modeSource == .manual,
        "Session invalidation changed the user's manual workday choice")

    plugin.failure = nil
    plugin.value = PluginSnapshot(pluginID: plugin.descriptor.id, fetchedAt: now.addingTimeInterval(1),
        leave: nil, vacations: [], events: [], coverage: PluginCoverage(calendarFrom: day, calendarThrough: day))
    try await registry.refresh(plugin.descriptor.id); controller.sessionRevision += 1
    try await waitForArchitecture("Account B fresh read did not replace the missing snapshot message") {
        automatic.calendarHalfDayMessage != FeatureAdapterFailure.missingSnapshot.localizedDescription
    }
    require(automatic.detectedModeToday == nil && automatic.arrival?.mode == .normal,
        "Account B inherited account A's half-day after recovery")
    print("PASS half-day session invalidation: same source, CAPTCHA wait, automatic reset, manual preservation, transient failure and recovery")
}

actor ProbeCalendarAccess: CalendarSyncAccess {
    private(set) var requests = 0
    private(set) var reads = 0
    func requestAccess() { requests += 1 }
    func writableCalendars() -> [SystemCalendarSummary] { reads += 1; return [] }
    func counts() -> (Int, Int) { (requests, reads) }
}

@MainActor
private func checkOptionalCatalog(root: URL) async throws {
    let access = ProbeCalendarAccess()
    let sync = CalendarSyncModel(calendarAccess: access, runtimeAllowed: false)
    let store = PluginCatalogStore(url: root.appendingPathComponent("optional.json"))
    let manager = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(),
        routingStore: FeatureRoutingStore(url: nil), catalogStore: store)
    let presentations = PluginSettingsPresentationRegistry()
    manager.configureCatalog(sync: sync, presentations: presentations, modules: [], allowsExternalIntegrations: false)
    manager.start(); sync.start(); sync.prepareForDisplay()
    await sync.requestCalendarAccess()
    let initialCounts = await access.counts()
    require(manager.installed.isEmpty && initialCounts == (0, 0) && !sync.runtimeAllowed,
        "Fresh core-only startup must not read calendars or ask permission")
    let noEvents = try await manager.router.calendarEvents(in: DateInterval(start: Date(), duration: 60))
    require(noEvents == [],
        "Core calendar fallback must be empty")
    require(manager.catalog.first(where: { $0.id == "daouoffice" })?.author == "손정열"
        && manager.catalog.first(where: { $0.id == "daouoffice" })?.available == false,
        "Unavailable Daou build must retain truthful catalog metadata")
    manager.install("mac-calendar")
    require(manager.isInstalled("mac-calendar") && !manager.isEnabled("mac-calendar"), "Install and enable are distinct")
    manager.setEnabled("mac-calendar", true)
    require(manager.isEnabled("mac-calendar") && !sync.runtimeAllowed, "Dev catalog must never start external integrations")
    manager.install("leave-detection"); manager.setEnabled("leave-detection", true)
    let legacyState = AttendanceState()
    let attendanceStore = StateStore(url: root.appendingPathComponent("optional-attendance.json"))
    try attendanceStore.save(legacyState)
    let attendance = AppModel(store: attendanceStore, featureRouter: manager.router, allowsLoginItemChanges: false)
    attendance.observeFeatures(manager)
    require(attendance.setDayType(.annualLeave), "Core manual day type must work with integrations blocked")
    manager.setEnabled("mac-calendar", false)
    require(manager.isInstalled("mac-calendar") && !manager.isEnabled("mac-calendar"), "Disable must preserve installation")
    let restarted = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(), routingStore: FeatureRoutingStore(url: nil), catalogStore: store)
    restarted.configureCatalog(sync: sync, presentations: PluginSettingsPresentationRegistry(), modules: [], allowsExternalIntegrations: false)
    require(restarted.isInstalled("mac-calendar") && !restarted.isEnabled("mac-calendar") && restarted.isEnabled("leave-detection"),
        "Independent optional states must survive restart")
    let migrationStore = PluginCatalogStore(url: root.appendingPathComponent("migration.json"))
    let migration = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(), routingStore: FeatureRoutingStore(url: nil), catalogStore: migrationStore)
    migration.configureCatalog(sync: sync, presentations: PluginSettingsPresentationRegistry(), modules: [], allowsExternalIntegrations: false)
    migration.migrateLegacy(calendarConfigured: true, daouConfigured: true, detectsHalfDays: true)
    require(["mac-calendar", "daouoffice", "leave-detection"].allSatisfy { migration.isEnabled($0) },
        "Legacy configured modules must migrate without disconnecting")
    migration.setEnabled("daouoffice", false)
    require(migration.isInstalled("daouoffice") && !migration.isEnabled("daouoffice"),
        "Excluded builds must still allow disabling a legacy installed module")
    migration.setEnabled("daouoffice", true)
    require(!migration.isEnabled("daouoffice") && migration.message != nil,
        "Excluded modules must not pretend to enable")
    migration.setEnabled("mac-calendar", false)
    let before = try Data(contentsOf: migrationStore.url!)
    migration.migrateLegacy(calendarConfigured: true, daouConfigured: true, detectsHalfDays: true)
    let after = try Data(contentsOf: migrationStore.url!)
    require(before == after && !migration.isEnabled("mac-calendar"), "Migration must not rerun over an explicit disabled state")
    let blockedURL = root.appendingPathComponent("catalog-blocker")
    try Data("preserve".utf8).write(to: blockedURL)
    let blocked = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(), routingStore: FeatureRoutingStore(url: nil),
        catalogStore: PluginCatalogStore(url: blockedURL.appendingPathComponent("catalog.json")))
    blocked.configureCatalog(sync: sync, presentations: PluginSettingsPresentationRegistry(), modules: [], allowsExternalIntegrations: false)
    blocked.install("mac-calendar")
    require(!blocked.isInstalled("mac-calendar") && blocked.message != nil, "Failed save must not pretend installation succeeded")
    print("PASS optional modules: core-only startup, metadata, distinct install/enable, restart, migration, save failure, Dev isolation and manual attendance")
}

@MainActor
private enum RetainedDaouModule: PluginModule {
    static let id = "daouoffice"
    static func register(in context: PluginHostContext) throws {}
}

@MainActor
private func checkLegacyBuiltinMigration(root: URL) throws {
    let sync = CalendarSyncModel(calendarAccess: ProbeCalendarAccess(), runtimeAllowed: false)
    func makeManager(_ routes: FeatureRoutingStore, _ catalog: PluginCatalogStore) -> PluginManagerModel {
        let manager = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(), routingStore: routes, catalogStore: catalog)
        manager.configureCatalog(sync: sync, presentations: PluginSettingsPresentationRegistry(), modules: [])
        return manager
    }
    let routes = FeatureRoutingStore(url: root.appendingPathComponent("legacy-builtin-routes.json"))
    let catalog = PluginCatalogStore(url: root.appendingPathComponent("legacy-builtin-catalog.json"))
    try routes.save([.calendar: "builtin", .halfDay: "builtin", .leave: "builtin"])
    let manager = makeManager(routes, catalog)
    manager.migrateLegacy(calendarConfigured: true, daouConfigured: false, detectsHalfDays: false)
    let migrated = try routes.load()
    require(migrated == [.calendar: "mac-calendar", .halfDay: "mac-calendar", .leave: "builtin"],
        "Legacy builtin calendar/half-day routes must become Mac Calendar while leave stays builtin")
    require(manager.router.selectedID(for: .calendar) == "mac-calendar" && manager.router.selectedID(for: .halfDay) == "mac-calendar",
        "Legacy routes were persisted but not activated")
    let restarted = makeManager(routes, catalog)
    require(restarted.router.selectedID(for: .calendar) == "mac-calendar" && restarted.router.selectedID(for: .halfDay) == "mac-calendar",
        "Migrated legacy routes did not survive restart")
    restarted.select("builtin", for: .calendar)
    restarted.select("builtin", for: .halfDay)
    let explicitBytes = try Data(contentsOf: routes.url!)
    restarted.migrateLegacy(calendarConfigured: true, daouConfigured: true, detectsHalfDays: true)
    let explicitRestart = makeManager(routes, catalog)
    let retainedBytes = try Data(contentsOf: routes.url!)
    require(retainedBytes == explicitBytes && explicitRestart.router.selectedID(for: .calendar) == "builtin"
        && explicitRestart.router.selectedID(for: .halfDay) == "builtin", "Existing catalog must preserve new explicit builtin routes")

    let emptyCatalog = PluginCatalogStore(url: root.appendingPathComponent("empty-existing-catalog.json"))
    let disconnectedRoutes = FeatureRoutingStore(url: root.appendingPathComponent("empty-existing-routes.json"))
    try emptyCatalog.save(PluginCatalogState())
    try disconnectedRoutes.save([.calendar: "builtin", .halfDay: "builtin"])
    let disconnected = makeManager(disconnectedRoutes, emptyCatalog)
    disconnected.migrateLegacy(calendarConfigured: true, daouConfigured: false, detectsHalfDays: true)
    let disconnectedDesired = try disconnectedRoutes.load()
    require(disconnected.installed.isEmpty && disconnectedDesired == [.calendar: "builtin", .halfDay: "builtin"],
        "An existing empty catalog still marks a post-upgrade explicit disconnect")

    let profileRoutes = FeatureRoutingStore(url: root.appendingPathComponent("attendance-only-routes.json"))
    let profileCatalog = PluginCatalogStore(url: root.appendingPathComponent("attendance-only-catalog.json"))
    let profile = makeManager(profileRoutes, profileCatalog)
    profile.migrateLegacy(calendarConfigured: false, daouConfigured: false, detectsHalfDays: false, hasLegacyAttendance: true)
    let profileDesired = try profileRoutes.load()
    require(profile.isEnabled("mac-calendar") && profileDesired == [.calendar: "mac-calendar", .halfDay: "mac-calendar"],
        "An existing attendance profile must retain implicit legacy Mac Calendar defaults")

    for (name, input, expected) in [
        ("mixed", [AppFeature.calendar: "daouoffice", .halfDay: "builtin", .leave: "daouoffice"],
            [AppFeature.calendar: "daouoffice", .halfDay: "mac-calendar", .leave: "daouoffice"]),
        ("third-party", [AppFeature.calendar: "daouoffice", .halfDay: "daouoffice", .leave: "builtin"],
            [AppFeature.calendar: "daouoffice", .halfDay: "daouoffice", .leave: "builtin"]),
        ("implicit-route-default", [AppFeature.leave: "builtin"],
            [AppFeature.calendar: "mac-calendar", .halfDay: "mac-calendar", .leave: "builtin"]),
        ("empty-route-default", [:], [AppFeature.calendar: "mac-calendar", .halfDay: "mac-calendar"]),
        ("interrupted-migration", [AppFeature.calendar: "mac-calendar", .halfDay: "mac-calendar"],
            [AppFeature.calendar: "mac-calendar", .halfDay: "mac-calendar"])
    ] {
        let routing = FeatureRoutingStore(url: root.appendingPathComponent(name + "-routes.json"))
        let catalog = PluginCatalogStore(url: root.appendingPathComponent(name + "-catalog.json"))
        try routing.save(input)
        let value = makeManager(routing, catalog)
        value.migrateLegacy(calendarConfigured: false, daouConfigured: false, detectsHalfDays: false)
        let actual = try routing.load()
        require(value.isEnabled("mac-calendar") && actual == expected,
            "Legacy routing migration lost explicit third-party choices or implicit Mac defaults: " + name)
    }
    let freshRoutes = FeatureRoutingStore(url: root.appendingPathComponent("fresh-migration-routes.json"))
    let freshCatalog = PluginCatalogStore(url: root.appendingPathComponent("fresh-migration-catalog.json"))
    let fresh = makeManager(freshRoutes, freshCatalog)
    fresh.migrateLegacy(calendarConfigured: false, daouConfigured: false, detectsHalfDays: false)
    require(fresh.installed.isEmpty && fresh.router.selectedID(for: .calendar) == "builtin"
        && !FileManager.default.fileExists(atPath: freshRoutes.url!.path), "Fresh install must remain core-only")

    let corruptRoutes = FeatureRoutingStore(url: root.appendingPathComponent("corrupt-legacy-routes.json"))
    let corruptCatalog = PluginCatalogStore(url: root.appendingPathComponent("corrupt-legacy-catalog.json"))
    let corruptBytes = Data("preserve corrupt routing".utf8)
    try corruptBytes.write(to: corruptRoutes.url!)
    let corrupt = makeManager(corruptRoutes, corruptCatalog)
    corrupt.migrateLegacy(calendarConfigured: true, daouConfigured: true, detectsHalfDays: true)
    let corruptAfter = try Data(contentsOf: corruptRoutes.url!)
    require(corruptAfter == corruptBytes && !FileManager.default.fileExists(atPath: corruptCatalog.url!.path)
        && !corrupt.canChangeCatalog && !corrupt.canChangeRoutes, "Corrupt routing must block migration and preserve bytes")

    let readonlyDirectory = root.appendingPathComponent("readonly-route-migration")
    let failedRoutes = FeatureRoutingStore(url: readonlyDirectory.appendingPathComponent("routes.json"))
    let failedCatalog = PluginCatalogStore(url: root.appendingPathComponent("failed-route-write-catalog.json"))
    try failedRoutes.save([.calendar: "builtin"])
    let originalFailedRoutes = try Data(contentsOf: failedRoutes.url!)
    let routeFailure = makeManager(failedRoutes, failedCatalog)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readonlyDirectory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonlyDirectory.path) }
    routeFailure.migrateLegacy(calendarConfigured: true, daouConfigured: false, detectsHalfDays: false)
    let routesAfterWriteFailure = try Data(contentsOf: failedRoutes.url!)
    require(!FileManager.default.fileExists(atPath: failedCatalog.url!.path) && !routeFailure.canChangeCatalog,
        "Route write failure must not write migration completion")
    require(originalFailedRoutes == routesAfterWriteFailure, "Failed route save changed source routing bytes")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonlyDirectory.path)
    let repairedRoute = makeManager(failedRoutes, failedCatalog)
    require(repairedRoute.needsLegacyMigration, "Repairing route permissions must allow migration on next launch")
    repairedRoute.migrateLegacy(calendarConfigured: true, daouConfigured: false, detectsHalfDays: false)
    let repairedRouteDesired = try failedRoutes.load()
    let repairedRouteCatalog = try failedCatalog.load()
    require(!repairedRoute.needsLegacyMigration && repairedRoute.canChangeRoutes && repairedRouteCatalog?.installed["mac-calendar"] == true
        && repairedRouteDesired == [.calendar: "mac-calendar", .halfDay: "mac-calendar"],
        "Migration did not complete after repairing route permissions")

    let catalogBlocker = root.appendingPathComponent("legacy-catalog-write-blocker")
    try Data("preserve catalog blocker".utf8).write(to: catalogBlocker)
    for existingRoutes in [false, true] {
        let routing = FeatureRoutingStore(url: root.appendingPathComponent("rollback-routes-\(existingRoutes).json"))
        let catalog = PluginCatalogStore(url: catalogBlocker.appendingPathComponent("catalog.json"))
        let original = Data("{ \"calendar\" : \"builtin\", \"leave\" : \"daouoffice\" }\n".utf8)
        if existingRoutes { try original.write(to: routing.url!) }
        let failed = makeManager(routing, catalog)
        failed.migrateLegacy(calendarConfigured: true, daouConfigured: false, detectsHalfDays: false)
        require(!failed.canChangeCatalog && !failed.canChangeRoutes && failed.message != nil,
            "Failed catalog migration must leave all settings read-only")
        if existingRoutes {
            let restored = try Data(contentsOf: routing.url!)
            require(restored == original, "Catalog write failure must restore exact original routing bytes")
        } else {
            require(!FileManager.default.fileExists(atPath: routing.url!.path), "Failed migration left a new routing file behind")
        }
        failed.select("builtin", for: .leave)
        if existingRoutes {
            let preserved = try Data(contentsOf: routing.url!)
            require(preserved == original, "Explicit selection changed routes after migration failure")
        }
        let retry = makeManager(routing, catalog)
        require(retry.needsLegacyMigration, "Failed migration must retry on next launch")
    }
    try FileManager.default.removeItem(at: catalogBlocker)
    try FileManager.default.createDirectory(at: catalogBlocker, withIntermediateDirectories: false)
    let repairedRouting = FeatureRoutingStore(url: root.appendingPathComponent("rollback-routes-true.json"))
    let repairedCatalog = PluginCatalogStore(url: catalogBlocker.appendingPathComponent("catalog.json"))
    let repaired = makeManager(repairedRouting, repairedCatalog)
    require(repaired.needsLegacyMigration, "Repairing catalog storage must leave migration pending until it is saved")
    repaired.migrateLegacy(calendarConfigured: true, daouConfigured: false, detectsHalfDays: false)
    let repairedDesired = try repairedRouting.load()
    let repairedState = try repairedCatalog.load()
    require(!repaired.needsLegacyMigration && repaired.canChangeCatalog && repaired.canChangeRoutes
        && repairedState?.installed["mac-calendar"] == true
        && repairedDesired == [.calendar: "mac-calendar", .halfDay: "mac-calendar", .leave: "daouoffice"],
        "Catalog repair/retry did not commit migrated routes and catalog together")
    print("PASS legacy builtin migration: explicit/missing routes, mixed Daou, restart, one-time mapping, fresh core-only, corrupt routing, transactional save failures and successful repair/retry")
}

@MainActor
private func checkDisabledRoutesAndMigration(root: URL) async throws {
    let routing = FeatureRoutingStore(url: root.appendingPathComponent("retained-routes.json"))
    let catalog = PluginCatalogStore(url: root.appendingPathComponent("retained-catalog.json"))
    let sync = CalendarSyncModel(calendarAccess: ProbeCalendarAccess(), runtimeAllowed: false)
    func makeManager() throws -> PluginManagerModel {
        let manager = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(), routingStore: routing, catalogStore: catalog)
        let controller = ProbeController("daouoffice")
        try manager.register(PluginRegistration(controller: controller, adapter: ProbeAdapter("daouoffice"),
            symbol: "calendar", summary: "fixture", setEnabled: { controller.enabled = $0 }))
        manager.configureCatalog(sync: sync, presentations: PluginSettingsPresentationRegistry(), modules: [RetainedDaouModule.self])
        return manager
    }
    // A preinstalled optional provider; no real module or credential is constructed.
    try catalog.save(PluginCatalogState(installed: ["daouoffice":true]))
    let manager = try makeManager()
    // Availability is tied to shipped module metadata; fixture uses Daou's module ID.
    for feature in AppFeature.allCases { manager.select("daouoffice", for: feature) }
    manager.setEnabled("daouoffice", false)
    for _ in 0..<20 { await Task.yield() }
    require(AppFeature.allCases.allSatisfy { manager.router.selectedID(for: $0) == manager.router.defaultID }, "Disabled provider remained active")
    let desired = try routing.load()
    require(AppFeature.allCases.allSatisfy { desired[$0] == "daouoffice" }, "Disabled desired routes were overwritten")
    manager.select(manager.router.defaultID, for: .leave)
    let restarted = try makeManager()
    restarted.setEnabled("daouoffice", true)
    for _ in 0..<20 { await Task.yield() }
    require(restarted.router.selectedID(for: .calendar) == "daouoffice" && restarted.router.selectedID(for: .halfDay) == "daouoffice"
        && restarted.router.selectedID(for: .leave) == restarted.router.defaultID, "Restart/re-enable lost intended routes or explicit disconnect")

    let rejected = try makeManager()
    rejected.install("mac-calendar")
    rejected.setEnabled("mac-calendar", true)
    rejected.select("daouoffice", for:.calendar)
    rejected.setEnabled("daouoffice", false)
    for _ in 0..<20 { await Task.yield() }
    let backup = root.appendingPathComponent("routes-before-save-failure.json")
    try FileManager.default.moveItem(at:routing.url!, to:backup)
    try FileManager.default.createDirectory(at:routing.url!, withIntermediateDirectories:false)
    rejected.select("mac-calendar", for:.calendar)
    require(rejected.message != nil, "Fixture did not reject route save")
    try FileManager.default.removeItem(at:routing.url!)
    try FileManager.default.moveItem(at:backup, to:routing.url!)
    rejected.install("leave-detection")
    rejected.setEnabled("leave-detection", true)
    rejected.setEnabled("daouoffice", true)
    require(rejected.router.selectedID(for:.calendar) == "daouoffice", "Rejected route save later overwrote disabled desired connection")

    let macRoutes = FeatureRoutingStore(url:root.appendingPathComponent("explicit-core-routes.json"))
    let macCatalog = PluginCatalogStore(url:root.appendingPathComponent("explicit-core-catalog.json"))
    try macCatalog.save(PluginCatalogState(installed:["mac-calendar":true]))
    func makeMacManager() -> PluginManagerModel {
        let value = PluginManagerModel(defaultAdapter:DefaultFeatureAdapter(), routingStore:macRoutes, catalogStore:macCatalog)
        value.configureCatalog(sync:sync, presentations:PluginSettingsPresentationRegistry(), modules:[])
        return value
    }
    let macManager = makeMacManager()
    macManager.select(macManager.router.defaultID, for:.calendar)
    macManager.select(macManager.router.defaultID, for:.halfDay)
    macManager.setEnabled("mac-calendar", false)
    macManager.setEnabled("mac-calendar", true)
    require(macManager.router.selectedID(for:.calendar) == macManager.router.defaultID && macManager.router.selectedID(for:.halfDay) == macManager.router.defaultID,
        "Mac re-enable erased explicit core selection")
    let macRestart = makeMacManager()
    require(macRestart.router.selectedID(for:.calendar) == macRestart.router.defaultID && macRestart.router.selectedID(for:.halfDay) == macRestart.router.defaultID,
        "Mac restart erased explicit core selection")

    let blocked = root.appendingPathComponent("sync-store-blocker")
    let bytes = Data("preserved blocker".utf8)
    try bytes.write(to: blocked)
    let failingSync = CalendarSyncModel(runtimeAllowed: false, storeURL: blocked.appendingPathComponent("sync.sqlite"))
    do { _ = try await failingSync.legacyConfigured(); fatalError("Store initialization failure became unconfigured") }
    catch {}
    let retryCatalog = PluginCatalogStore(url: root.appendingPathComponent("retry-catalog.json"))
    let retryManager = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(), routingStore: FeatureRoutingStore(url:nil), catalogStore:retryCatalog)
    retryManager.reportMigrationFailure()
    require(!retryManager.canChangeCatalog && !FileManager.default.fileExists(atPath:retryCatalog.url!.path), "Failed migration wrote completion")
    let preserved = try Data(contentsOf:blocked)
    require(preserved == bytes, "Failed store initialization changed original")
    let nextLaunch = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(), routingStore: FeatureRoutingStore(url:nil), catalogStore:retryCatalog)
    require(nextLaunch.needsLegacyMigration, "Migration failure was not retryable")
    print("PASS disabled route restart/restoration and migration initialization failure")
}

@MainActor
private func checkUnreadableCatalogPreservesAttendance(root: URL) async throws {
    for migrationFailed in [false, true] {
        let suffix = migrationFailed ? "migration-failed" : "catalog-corrupt"
        let catalogURL = root.appendingPathComponent(suffix + ".json")
        let corrupt = Data("preserve corrupt catalog".utf8)
        if !migrationFailed { try corrupt.write(to: catalogURL) }
        let manager = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(), routingStore: FeatureRoutingStore(url: nil),
            catalogStore: PluginCatalogStore(url: catalogURL))
        let sync = CalendarSyncModel(calendarAccess: ProbeCalendarAccess(), runtimeAllowed: false)
        manager.configureCatalog(sync: sync, presentations: PluginSettingsPresentationRegistry(), modules: [])
        if migrationFailed { manager.reportMigrationFailure() }
        let now = Date(), calendar = Calendar.current
        let day = Attendance.dayKey(now, calendar: calendar)
        let arrivalTime = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        var state = AttendanceState(); state.didOfferLoginItem = true; state.detectHalfDaysFromCalendar = true
        state.arrivals[day] = Arrival(day: day, time: arrivalTime, source: .unlock,
            timeZoneID: calendar.timeZone.identifier, mode: .afternoonHalf, modeSource: .automatic, earlyLeaveOverrideMinutes: 0)
        let store = StateStore(url: root.appendingPathComponent(suffix + "-attendance.json"))
        try store.save(state)
        let bytesBefore = try Data(contentsOf: store.url)
        let model = AppModel(store: store, featureRouter: manager.router, allowsLoginItemChanges: false)
        model.observeFeatures(manager); model.refresh(); model.checkCalendarHalfDayNow()
        for _ in 0..<40 { await Task.yield() }
        let bytesAfter = try Data(contentsOf: store.url)
        require(model.state == state && bytesBefore == bytesAfter && model.arrival?.mode == .afternoonHalf,
            "Unreadable catalog or failed migration must preserve automatic attendance bytes and mode")
        if !migrationFailed {
            let preserved = try Data(contentsOf: catalogURL)
            require(preserved == corrupt, "Corrupt catalog must remain unchanged alongside attendance")
        }
    }
    print("PASS unreadable catalog/migration: automatic half-day attendance state and bytes preserved")
}

@MainActor
private func checkLeaveGateInvalidation(root: URL) async throws {
    let sync = CalendarSyncModel(calendarAccess: ProbeCalendarAccess(), runtimeAllowed: false)
    let manager = PluginManagerModel(defaultAdapter: DefaultFeatureAdapter(), routingStore: FeatureRoutingStore(url: nil))
    let controller = ProbeController("mac-calendar"), adapter = ProbeAdapter("mac-calendar")
    controller.enabled = false
    try manager.register(PluginRegistration(controller: controller, adapter: adapter, symbol: "calendar", summary: "Fixture",
        setEnabled: { controller.enabled = $0 }))
    manager.configureCatalog(sync: sync, presentations: PluginSettingsPresentationRegistry(), modules: [])
    manager.install("mac-calendar"); manager.setEnabled("mac-calendar", true)
    manager.install("leave-detection"); manager.setEnabled("leave-detection", true)
    var state = AttendanceState(); state.didOfferLoginItem = true; state.detectHalfDaysFromCalendar = true
    let store = StateStore(url: root.appendingPathComponent("leave-gate.json")); try store.save(state)
    let model = AppModel(store: store, featureRouter: manager.router, allowsLoginItemChanges: false)
    model.observeFeatures(manager)
    // Let the initial observation settle, then hold a real in-flight title response.
    for _ in 0..<20 { await Task.yield() }
    adapter.pausesHalfDays = true
    model.checkCalendarHalfDayNow()
    try await waitForArchitecture("Half-day fixture never started") { adapter.heldHalfDay != nil }
    manager.setEnabled("leave-detection", false)
    manager.setEnabled("leave-detection", true)
    adapter.pausesHalfDays = false
    adapter.heldHalfDay?.resume(returning: ["오후 반차"]); adapter.heldHalfDay = nil
    for _ in 0..<30 { await Task.yield() }
    require(model.detectedModeToday == nil, "A reply from before disable/re-enable must not restore stale half-day mode")
    manager.setEnabled("leave-detection", false)
    require(model.setDayType(.morningHalf), "Manual half-day must still work with automatic recognition disabled")
    require(model.effectiveDayType == .morningHalf, "Optional gate must preserve manual day selection")
    var intentState = AttendanceState(); intentState.didOfferLoginItem = true
    let intentStore = StateStore(url: root.appendingPathComponent("leave-intent.json")); try intentStore.save(intentState)
    let intent = AppModel(store: intentStore, featureRouter: manager.router, allowsLoginItemChanges: false)
    intent.observeFeatures(manager)
    manager.setEnabled("leave-detection", true)
    manager.select(manager.router.defaultID, for: .halfDay)
    intent.setCalendarHalfDayDetection(true)
    try await waitForArchitecture("Leave enable intent was lost without a connected source") { intent.state.detectHalfDaysFromCalendar }
    require(intent.calendarHalfDayMessage != nil, "Missing source must explain how to connect")
    adapter.titles = ["오후 반차"]
    manager.select("mac-calendar", for: .halfDay)
    try await waitForArchitecture("A later provider connection did not resume enabled detection") { intent.detectedModeToday == .afternoonHalf }
    intent.setCalendarHalfDayDetection(false)
    adapter.accessFailure = NSError(domain: "CalendarPermissionDeniedFixture", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "fixture permission denied"])
    intent.setCalendarHalfDayDetection(true)
    try await waitForArchitecture("Permission failure was not shown") { intent.calendarHalfDayMessage == "fixture permission denied" }
    require(!intent.state.detectHalfDaysFromCalendar, "Permission/unknown failures must preserve the disabled preference")
    adapter.accessFailure = nil
    intent.setCalendarHalfDayDetection(true)
    try await waitForArchitecture("Explicit permission retry did not enable detection") {
        intent.state.detectHalfDaysFromCalendar && intent.detectedModeToday == .afternoonHalf
    }
    intent.setCalendarHalfDayDetection(false)
    adapter.pausesAccess = true
    intent.setCalendarHalfDayDetection(true)
    try await waitForArchitecture("Permission fixture never started") { adapter.heldAccess != nil }
    manager.setEnabled("leave-detection", false); manager.setEnabled("leave-detection", true)
    adapter.pausesAccess = false
    adapter.heldAccess?.resume(); adapter.heldAccess = nil
    for _ in 0..<30 { await Task.yield() }
    require(!intent.state.detectHalfDaysFromCalendar, "A stale permission reply must not restore disabled recognition intent")
    print("PASS leave recognition lifecycle: stale title/permission replies, manual selection, enabled intent before connection and permission retry")
}

@main
struct PluginArchitectureChecks {
    @MainActor
    static func main() async throws {
        // Keep legacy menu assertions independent of a previous probe's saved toggle.
        let departureKey = "HappyLuluShowDepartureInMenuBar"
        let savedDepartureVisibility = UserDefaults.standard.object(forKey: departureKey)
        UserDefaults.standard.removeObject(forKey: departureKey)
        defer {
            if let savedDepartureVisibility { UserDefaults.standard.set(savedDepartureVisibility, forKey: departureKey) }
            else { UserDefaults.standard.removeObject(forKey: departureKey) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HappyLulu-architecture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try checkMenuCountdownDisplay(root: root)
        try checkInjectedAttendanceClock(root: root)
        try await checkInjectedAsyncClock(root: root)
        try checkLegacyBuiltinMigration(root: root)
        try await checkOptionalCatalog(root: root)
        try await checkDisabledRoutesAndMigration(root: root)
        try await checkUnreadableCatalogPreservesAttendance(root: root)
        try await checkLeaveGateInvalidation(root: root)
        let catalogURL = root.appendingPathComponent("catalog.json")
        let catalogStore = PluginCatalogStore(url: catalogURL)
        let emptyCatalog = try catalogStore.load()
        require(emptyCatalog == nil, "Fresh catalog must contain no optional modules")
        var catalogState = PluginCatalogState()
        catalogState.installed["mac-calendar"] = true
        try catalogStore.save(catalogState)
        let restartedCatalog = try catalogStore.load()
        require(restartedCatalog?.installed["mac-calendar"] == true, "Installation must survive restart")
        let corruptCatalogBytes = Data("broken catalog".utf8)
        try corruptCatalogBytes.write(to: catalogURL)
        let protectedManager = PluginManagerModel(defaultAdapter: ProbeAdapter("builtin"),
            routingStore: FeatureRoutingStore(url: nil), catalogStore: catalogStore)
        protectedManager.install("mac-calendar")
        require(!protectedManager.canChangeCatalog && protectedManager.message != nil,
            "Corrupt catalog must be read only")
        let preservedCatalogBytes = try Data(contentsOf: catalogURL)
        require(preservedCatalogBytes == corruptCatalogBytes, "Corrupt catalog must remain byte identical")
        print("PASS plugin catalog persistence and corruption preservation")
        let manualDayStore = StateStore(url: root.appendingPathComponent("manual-day.json"))
        let manualDayRouter = PluginManagerModel(defaultAdapter: ProbeAdapter("builtin"), routingStore: FeatureRoutingStore(url: nil))
        let manualDayModel = AppModel(store: manualDayStore, featureRouter: manualDayRouter.router)
        require(manualDayModel.setDayType(.annualLeave), "Annual leave must save without calendar access")
        require(manualDayModel.todayDayType == .annualLeave && manualDayModel.arrival == nil && manualDayModel.isSkipped,
                "Annual leave must pause today's attendance")
        let loadedDay = AppModel(store: manualDayStore, featureRouter: manualDayRouter.router)
        require(loadedDay.todayDayType == .annualLeave, "Annual leave must survive restart")
        require(loadedDay.setDayType(.afternoonHalf) && loadedDay.arrival == nil && !loadedDay.isSkipped,
                "Half-day choice must resume without inventing an arrival")
        let persistedDay = try manualDayStore.load()
        require(persistedDay.manualDayTypes[loadedDay.dayKey(loadedDay.now)] == .afternoonHalf,
                "Half-day choice must be persisted")
        print("PASS manual day AppModel: calendar-free annual/half-day selection, restart, no invented arrival")
        require(loadedDay.setDayType(.luluDay) && loadedDay.effectiveDayType == .luluDay,
                "Pending Lulu day must be reflected by the compact selector")
        require(loadedDay.arrival == nil, "Lulu selection must not invent an arrival")
        let priorFailedClock = loadedDay.state
        require(!loadedDay.saveManual(loadedDay.now.addingTimeInterval(3600), selectedMode: nil)
                && loadedDay.state == priorFailedClock, "Future manual time must be rejected without changing data")
        require(!loadedDay.saveManualClockText("25:99", forDay: loadedDay.dayKey(loadedDay.now)),
                "Invalid inline clock must be rejected")
        var clockCalendar = Calendar(identifier: .gregorian)
        clockCalendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let fixtureCalendar = clockCalendar
        let fixtureNow = clockCalendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 16))!
        let fixtureClock = clockCalendar.date(bySettingHour: 9, minute: 0, second: 0, of: fixtureNow)!
        var clockState = AttendanceState(); clockState.didOfferLoginItem = true
        let clockDay = Attendance.dayKey(fixtureClock, calendar: clockCalendar)
        clockState.arrivals[clockDay] = Arrival(day: clockDay, time: fixtureClock, source: .manual,
            timeZoneID: clockCalendar.timeZone.identifier, mode: .normal, modeSource: .manual, earlyLeaveOverrideMinutes: 0)
        let clockStore = StateStore(url: root.appendingPathComponent("compact-clock.json"))
        try clockStore.save(clockState)
        let clockModel = AppModel(store: clockStore, featureRouter: manualDayRouter.router, allowsLoginItemChanges: false,
                                  nowProvider: { fixtureNow }, calendarProvider: { fixtureCalendar })
        require(clockModel.menuTitle.hasPrefix(L("퇴근 18:00", "Leave 18:00")), "Compact menu must use explicit 24-hour departure")
        clockModel.setLoginEnabled(true)
        require(clockModel.errorMessage != nil && clockModel.state == clockState,
                "Development app must not register login items")
        let beforeBadClock = clockModel.state
        require(!clockModel.saveManualClockText("9:00", forDay: clockDay) && clockModel.state == beforeBadClock,
                "Inline clock requires strict HH:mm without mutating saved state")
        require(!clockModel.saveManualClockText("09:00", forDay: "1900-01-01") && clockModel.state == beforeBadClock,
                "Inline clock must reject a stale editing date")
        print("PASS compact panel model: explicit 24-hour title, login isolation and invalid/stale inline input preservation")
        let regressionCalendar = fixtureCalendar
        let regressionTime = fixtureClock
        let regressionDay = Attendance.dayKey(regressionTime, calendar: regressionCalendar)
        var regressionState = AttendanceState()
        regressionState.didOfferLoginItem = true
        regressionState.detectHalfDaysFromCalendar = true
        _ = Attendance.recordUnlock(in: &regressionState, at: regressionTime, calendar: regressionCalendar)
        let regressionStore = StateStore(url: root.appendingPathComponent("attendance-regressions.json"))
        try regressionStore.save(regressionState)
        let regressionAdapter = ProbeAdapter("regression")
        let regressionRouter = PluginManagerModel(defaultAdapter: regressionAdapter, routingStore: FeatureRoutingStore(url: nil))
        let regressionModel = AppModel(store: regressionStore, featureRouter: regressionRouter.router, allowsLoginItemChanges: false,
                                       nowProvider: { fixtureNow }, calendarProvider: { fixtureCalendar })
        require(regressionModel.saveManualClockText("09:01", forDay: regressionDay), "Clock-only edit must save")
        require(regressionModel.arrival?.modeSource == .automatic && regressionModel.todayDayType == nil,
                "Clock-only edit must preserve automatic workday mode")
        regressionAdapter.titles = ["오후 반차"]
        regressionModel.checkCalendarHalfDayNow()
        try await waitForArchitecture("Calendar change after a clock edit was ignored") {
            regressionModel.arrival?.mode == .afternoonHalf
        }
        require(regressionModel.setDayType(.annualLeave), "Annual leave must save with an existing arrival")
        require(regressionModel.state.arrivals[regressionDay] != nil && regressionModel.isSkipped,
                "Annual leave must preserve the arrival and pause automatic attendance")
        require(regressionModel.canSkipToday, "Annual leave must leave the distinct arrival-deletion action enabled")
        regressionModel.skipToday()
        require(regressionModel.state.arrivals[regressionDay] == nil && regressionModel.todayDayType == nil
                && regressionModel.isSkipped && !regressionModel.canSkipToday,
                "Taking today off must clear the retained arrival and leave selection")
        require(regressionModel.saveManualClockText("09:02", forDay: regressionDay, dayType: .luluDay),
                "Combined Lulu selection and clock edit must save")
        require(regressionModel.arrival?.earlyLeaveOverrideMinutes == 120 && regressionModel.todayDayType == .luluDay,
                "Explicit Lulu choice must retain its reduction")
        require(regressionModel.saveManualClockText("09:03", forDay: regressionDay)
                && regressionModel.arrival?.earlyLeaveOverrideMinutes == 120
                && regressionModel.arrival?.modeSource == .manual && regressionModel.todayDayType == .luluDay,
                "Clock-only edit must preserve the existing manual Lulu choice")
        require(regressionModel.saveManualClockText("09:04", forDay: regressionDay, dayType: .regular)
                && regressionModel.arrival?.earlyLeaveOverrideMinutes == 0 && regressionModel.todayDayType == .regular,
                "Combined regular selection and clock edit must clear the Lulu reduction")
        print("PASS attendance regressions: inline clock preserves calendar updates; annual leave permits arrival deletion")
        // A real unchanged default must persist, not be mistaken for an unchanged existing arrival.
        let defaultNow = fixtureClock
        let defaultClockStore = StateStore(url: root.appendingPathComponent("default-clock.json"))
        let defaultClockModel = AppModel(store: defaultClockStore, featureRouter: manualDayRouter.router,
                                         allowsLoginItemChanges: false, nowProvider: { defaultNow },
                                         calendarProvider: { fixtureCalendar })
        let defaultDraft = ArrivalClockEdit(existingTime: nil, now: defaultClockModel.now,
                                            timeZone: defaultClockModel.calendar.timeZone)
        require(defaultDraft.needsSave && defaultClockModel.saveManualClockText(defaultDraft.text,
                    forDay: defaultClockModel.dayKey(defaultClockModel.now)),
                "An untouched current-time draft must save on dismissal")
        let persistedDefaultClock = try defaultClockStore.load()
        require(defaultClockModel.arrival != nil && defaultClockModel.departure != nil
                && persistedDefaultClock == defaultClockModel.state,
                "Default clock must persist a real arrival and update departure")
        print("PASS default arrival: untouched current-time draft persists and calculates departure")

        let store = FeatureRoutingStore(url: root.appendingPathComponent("routes.json"))
        let absentStore = FeatureRoutingStore(url: root.appendingPathComponent("removed-plugin.json"))
        try absentStore.save([.calendar: "daouoffice", .leave: "daouoffice", .halfDay: "daouoffice"])
        let absent = PluginManagerModel(defaultAdapter: ProbeAdapter("builtin"), routingStore: absentStore)
        absent.start()
        require(absent.registrations.isEmpty && AppFeature.allCases.allSatisfy { absent.router.selectedID(for: $0) == "builtin" },
            "Removing a saved plugin prevented startup or left a missing source selected")
        absent.stop()
        let failedStore = FeatureRoutingStore(url: root.appendingPathComponent("failed-install.json"))
        try failedStore.save([.calendar: FailingModule.id, .leave: "later-plugin"])
        let priorRouteBytes = try Data(contentsOf: failedStore.url!)
        let failed = PluginManagerModel(defaultAdapter: ProbeAdapter("builtin"), routingStore: failedStore)
        let failedPresentations = PluginSettingsPresentationRegistry()
        failed.start()
        let failedContext = PluginHostContext(registry: failed.registry, presentations: failedPresentations,
            register: failed.register, rollback: failed.rollbackRegistration, localize: { korean, _ in korean })
        for stage in 0...2 {
            FailingModule.failureStage = stage
            BundledPlugins.register(in: failedContext, modules: [FailingModule.self], onFailure: failed.reportRegistrationFailure)
            require(failed.registrations.isEmpty && failed.registry.descriptors.isEmpty && !failedPresentations.contains(FailingModule.id),
                "A failed module left its controller, data provider or settings registered")
            require((stage == 0 || FailingModule.controller?.stops == 1) && failed.message != nil,
                "A failed module retained its lifecycle or suppressed the registration error")
            require(AppFeature.allCases.allSatisfy { failed.router.selectedID(for: $0) == "builtin" },
                "A failed module prevented default feature routing")
            let routeBytes = try Data(contentsOf: failedStore.url!)
            require(routeBytes == priorRouteBytes, "Installation rollback overwrote saved routes, including other pending plugins")
        }
        let survivor = ProbeController("later-plugin")
        try failed.register(PluginRegistration(controller: survivor, adapter: ProbeAdapter(survivor.descriptor.id), symbol: "leaf", summary: "Survivor"))
        require(failed.router.selectedID(for: .leave) == survivor.descriptor.id,
            "Failure of one module erased the later module's saved feature binding")
        let originalController = ProbeController(FailingModule.id)
        try failed.register(PluginRegistration(controller: originalController, adapter: ProbeAdapter(FailingModule.id), symbol: "calendar", summary: "Original"))
        try failed.registry.register(ProbeDataPlugin(FailingModule.id))
        try failedPresentations.register(FailingModule.id) { Text("Original settings") }
        failed.select(FailingModule.id, for: .calendar)
        let priorCalls = FailingModule.calls
        BundledPlugins.register(in: failedContext, modules: [FailingModule.self], onFailure: failed.reportRegistrationFailure)
        require(FailingModule.calls == priorCalls && failed.registrations.count == 2 && failed.registry.descriptors.count == 1 &&
            failedPresentations.contains(FailingModule.id) && originalController.stops == 0 && failed.router.selectedID(for: .calendar) == FailingModule.id,
            "Duplicate module installation removed the existing module or changed its routing")
        failed.stop()
        let builtin = ProbeAdapter("builtin"), alpha = ProbeAdapter("alpha"), beta = ProbeAdapter("beta")
        let first = ProbeController("alpha"), second = ProbeController("beta")
        let manager = PluginManagerModel(defaultAdapter: builtin, routingStore: store)
        try manager.register(PluginRegistration(controller: first, adapter: alpha, symbol: "calendar", summary: "Fixture"))
        try manager.register(PluginRegistration(controller: second, adapter: beta, symbol: "leaf", summary: "Fixture"))
        require(manager.registrations.count == 2, "Catalog supports only one plugin")
        do { try manager.register(PluginRegistration(controller: first, adapter: alpha, symbol: "calendar", summary: "Duplicate")); fatalError("Duplicate registration accepted") }
        catch {}
        manager.start(); manager.start()
        require(first.starts == 1 && second.starts == 1, "Repeated app startup duplicated plugin lifecycle")
        manager.select("alpha", for: .calendar); manager.select("beta", for: .leave)
        let routes = try store.load()
        require(routes[.calendar] == "alpha" && routes[.leave] == "beta", "Feature routing did not persist independently")
        let restarted = PluginManagerModel(defaultAdapter: ProbeAdapter("builtin"), routingStore: store)
        try restarted.register(PluginRegistration(controller: first, adapter: alpha, symbol: "calendar", summary: "Fixture"))
        try restarted.register(PluginRegistration(controller: second, adapter: beta, symbol: "leaf", summary: "Fixture"))
        require(restarted.router.selectedID(for: .calendar) == "alpha" && restarted.router.selectedID(for: .leave) == "beta", "Routing was lost on restart")
        manager.refreshSource(for: .calendar)
        require(first.refreshes == 1 && second.refreshes == 0, "Refreshing one feature refreshed unrelated plugins")
        first.enabled = false
        for _ in 0..<100 { if manager.router.selectedID(for: .calendar) == "builtin" { break }; await Task.yield() }
        require(manager.router.selectedID(for: .calendar) == "builtin" && manager.router.selectedID(for: .leave) == "beta", "Disabling a plugin changed unrelated bindings")
        let disabledRoutes = try store.load()
        require(disabledRoutes[.calendar] == "alpha" && disabledRoutes[.leave] == "beta", "Disabling erased the desired connection")
        first.enabled = true
        for _ in 0..<100 { if manager.router.selectedID(for: .calendar) == "alpha" { break }; await Task.yield() }
        require(manager.router.selectedID(for: .calendar) == "alpha", "Re-enabling did not restore desired route")
        manager.unregister("alpha")
        require(first.stops == 1 && manager.registrations.count == 1, "Unregistering a plugin did not stop only its own lifecycle")
        manager.stop(); require(second.stops == 1, "Shutdown did not stop registered plugins")

        let corrupted = root.appendingPathComponent("corrupt.json")
        let corruptBytes = Data("unrecognized settings".utf8); try corruptBytes.write(to: corrupted)
        let preserved = PluginManagerModel(defaultAdapter: ProbeAdapter("builtin"), routingStore: FeatureRoutingStore(url: corrupted))
        require(!preserved.canChangeRoutes && preserved.message != nil, "Unreadable routing was silently reset")
        let preservedBytes = try Data(contentsOf: corrupted)
        require(preservedBytes == corruptBytes, "Unreadable routing file was changed")

        let model = FeatureCalendarModel(router: manager.router)
        let start = try fixtureDate("2026-10-01T00:00:00+09:00")
        let interval = DateInterval(start: start, end: start.addingTimeInterval(86400))
        builtin.events = [FeatureCalendarEvent(sourceID: "builtin", eventID: "one", calendarID: "one", title: "Fixture", start: start, end: interval.end, isAllDay: true)]
        await model.load(in: interval)
        require(model.events.count == 1 && !model.isLoading && model.errorMessage == nil, "Calendar view model did not consume the selected default adapter")
        builtin.pauses = true
        let pending = Task { await model.load(in: interval) }
        while builtin.held == nil { await Task.yield() }
        manager.select("beta", for: .calendar)
        builtin.held?.resume(returning: builtin.events); builtin.held = nil
        await pending.value
        require(model.events.isEmpty, "Calendar view model displayed the previous source after switching")
        await model.load(in: interval)
        require(model.events.isEmpty && model.errorMessage == nil, "Second plugin did not bind to the same calendar view model")
        let presentations = PluginSettingsPresentationRegistry()
        try presentations.register("alpha") { Text("First plugin settings") }
        try presentations.register("beta") { Text("Second plugin settings") }
        require(presentations.view(for: "alpha") != nil && presentations.view(for: "beta") != nil, "Settings were hard-coded to a single plugin")
        do { try presentations.register("alpha") { Text("Replacement") }; fatalError("Duplicate presentation accepted") } catch {}

        try await checkHalfDaySessionInvalidation(root: root)

        var state = AttendanceState(); state.didOfferLoginItem = true
        let stateStore = StateStore(url: root.appendingPathComponent("attendance.json")); try stateStore.save(state)
        let attendance = AppModel(store: stateStore, featureRouter: manager.router)
        attendance.updateSettings(work: 480, rest: 60)
        let savedState = try stateStore.load()
        require(savedState.arrivals.isEmpty && savedState.didOfferLoginItem, "Adapter composition fabricated attendance or changed login setup")
        let attendanceManager = PluginManagerModel(defaultAdapter: ProbeAdapter("builtin"), routingStore: FeatureRoutingStore(url: nil))
        let leaveSource = ProbeAdapter("half-day"), leaveController = ProbeController("half-day")
        leaveSource.titles = ["오후 반차"]
        try attendanceManager.register(PluginRegistration(controller: leaveController, adapter: leaveSource, symbol: "calendar", summary: "Fixture"))
        attendanceManager.select("half-day", for: .halfDay)
        var detectedState = AttendanceState(); detectedState.didOfferLoginItem = true; detectedState.detectHalfDaysFromCalendar = true
        let now = Date(), calendar = Calendar.current
        let arrival = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        Attendance.recordUnlock(in: &detectedState, at: arrival, calendar: calendar, calendarMode: nil)
        let detectedStore = StateStore(url: root.appendingPathComponent("bound-attendance.json")); try detectedStore.save(detectedState)
        let bound = AppModel(store: detectedStore, featureRouter: attendanceManager.router)
        bound.observeFeatures(attendanceManager); bound.checkCalendarHalfDayNow()
        for _ in 0..<100 { if bound.calendarHalfDayMode == .afternoonHalf { break }; await Task.yield() }
        require(bound.arrival?.mode == .afternoonHalf, "Plugin half-day source was not bound to attendance processing")
        leaveController.enabled = false
        for _ in 0..<100 { if bound.arrival?.mode == .normal { break }; await Task.yield() }
        require(bound.arrival?.mode == .normal && bound.detectedModeToday == nil, "Disabling a half-day source retained its automatic workday mode")
        var manualState = detectedState
        try Attendance.setManual(in: &manualState, at: arrival, now: arrival.addingTimeInterval(60), calendar: calendar, selectedMode: .normal, calendarMode: nil)
        let manualStore = StateStore(url: root.appendingPathComponent("manual-attendance.json")); try manualStore.save(manualState)
        leaveController.enabled = true
        for _ in 0..<100 { if attendanceManager.router.isEnabled("half-day") { break }; await Task.yield() }
        attendanceManager.select("half-day", for: .halfDay)
        let manual = AppModel(store: manualStore, featureRouter: attendanceManager.router)
        manual.checkCalendarHalfDayNow()
        for _ in 0..<100 { if manual.calendarHalfDayMode == .afternoonHalf { break }; await Task.yield() }
        require(manual.arrival?.mode == .normal && manual.arrival?.modeSource == .manual,
                "A plugin half-day result overwrote the user's manual workday choice")
        print("PASS plugin architecture: missing plugin fallback, failed installation rollback, duplicate preservation, two controllers, settings factories, lifecycle isolation, route persistence/restart/fallback, corruption preservation, calendar binding, stale reads and local attendance")
        if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 {
            try await renderCatalog(at: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
    }

    /// Deterministic native view rendering with fixtures; never captures the user's desktop or account.
    @MainActor
    static func renderCatalog(at directory: URL) async throws {
        _ = NSApplication.shared
        let manager = PluginManagerModel(defaultAdapter: ProbeAdapter("builtin"), routingStore: FeatureRoutingStore(url: nil))
        let first = ProbeController("일정 플러그인 (검증용)"), second = ProbeController("휴가 플러그인 (검증용)")
        second.enabled = false
        try manager.register(PluginRegistration(controller: first, adapter: ProbeAdapter(first.descriptor.id), symbol: "calendar", summary: "일정과 반차를 제공하는 검증 데이터"))
        try manager.register(PluginRegistration(controller: second, adapter: ProbeAdapter(second.descriptor.id), symbol: "leaf", summary: "독립적으로 등록된 두 번째 검증 플러그인"))
        let presentations = PluginSettingsPresentationRegistry()
        let sync = CalendarSyncModel(calendarAccess: ProbeCalendarAccess(), runtimeAllowed: false)
        manager.configureCatalog(sync: sync, presentations: presentations, modules: [], allowsExternalIntegrations: false)
        manager.install("mac-calendar"); manager.install("leave-detection")
        let root = ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L("플러그인", "Plugins")).font(.title.bold())
                Text(L("플러그인과 앱 기능의 연결을 관리합니다.", "Manage plugins and their connections to app features."))
                    .foregroundStyle(.secondary)
                PluginSettingsView(model: manager, presentations: presentations, onOpenPlugin: { _ in },
                    onInstall: manager.install, onSetEnabled: manager.setEnabled, needsSetup: { _ in false })
            }.padding(28)
        }.frame(width: 630, height: 860)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(Color(red: 0.16, green: 0.48, blue: 0.42))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 860), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let hosting = NSHostingView(rootView: root.environment(\.colorScheme, scheme).environment(\.controlActiveState, .active))
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fatalError("Native catalog render unavailable") }
            window.appearance?.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
            guard let bytes = bitmap.representation(using: .png, properties: [:]) else { fatalError("Native catalog PNG unavailable") }
            try bytes.write(to: directory.appendingPathComponent("plugin-tab-\(name).png"))
            window.close()
        }
        print("PASS native plugin catalog rendering: light and dark fixture views")
    }
}
