import Foundation
import CalendarSyncCore
@testable import CalendarSyncServices

final class FakeSystemCalendarBackend: SystemCalendarBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: CalendarEvent] = [:]
    private var duplicateItems: [SystemCalendarRecord] = []
    private var calendarAvailable = true
    private var createReplyLost = false
    private var createCount = 0
    private var rejectedTitles: Set<String> = []

    func validateCalendar() throws {
        try lock.withLock {
            if !calendarAvailable { throw SystemCalendarError.calendarMissing }
        }
    }
    func events(start: Date, end: Date) throws -> [SystemCalendarRecord] {
        try lock.withLock {
            let records = items.values.map { SystemCalendarRecord(physicalID: "physical:" + $0.id, event: $0) } + duplicateItems
            return try records.filter {
                let (begin, finish) = try SystemCalendarSafety.dates(for: $0.event.content.time)
                return begin < end && finish > start
            }
        }
    }
    func event(id: String) throws -> CalendarEvent? { lock.withLock { items[id] } }
    func create(content: CalendarEventContent, marker: String) throws -> CalendarEvent {
        try lock.withLock {
            if rejectedTitles.contains(content.title) { throw SystemCalendarError.invalidDate }
            guard let mappingID = SystemCalendarSafety.marker(from: URL(string: marker)) else {
                throw SystemCalendarError.uncertainWrite
            }
            let event = CalendarEvent(id: "sync:" + mappingID, version: "created-v1",
                content: content, syncMarker: mappingID)
            items[event.id] = event
            createCount += 1
            if createReplyLost {
                createReplyLost = false
                throw CalendarHTTPError.responseMissing
            }
            return event
        }
    }
    func update(id: String, expectedVersion: String, content: CalendarEventContent) throws -> CalendarEvent {
        try lock.withLock {
            guard var event = items[id] else { throw SystemCalendarError.eventMissing }
            guard event.version == expectedVersion else { throw SystemCalendarError.eventChanged }
            event.content = content
            event.version = "updated-v2"
            items[id] = event
            return event
        }
    }
    func delete(id: String, expectedVersion: String) throws {
        try lock.withLock {
            guard let event = items[id] else { throw SystemCalendarError.eventMissing }
            guard event.version == expectedVersion else { throw SystemCalendarError.eventChanged }
            items.removeValue(forKey: id)
        }
    }
    func insert(_ event: CalendarEvent) { lock.withLock { items[event.id] = event } }
    func insertPhysicalDuplicate(_ event: CalendarEvent) {
        lock.withLock { duplicateItems.append(SystemCalendarRecord(physicalID: UUID().uuidString, event: event)) }
    }
    func removeAll() { lock.withLock { items = [:] } }
    func hideCalendar() { lock.withLock { calendarAvailable = false } }
    func loseCreateReply() { lock.withLock { createReplyLost = true } }
    func writes() -> Int { lock.withLock { createCount } }
    func rejectDate(forTitle title: String) { lock.withLock { _ = rejectedTitles.insert(title) } }
    func assignExternalIDsToCopies(removeMarkers: Bool = false) {
        lock.withLock {
            items = Dictionary(items.values.map { event in
                var event = event
                if let marker = event.syncMarker { event.id = "external:remote-" + marker }
                if removeMarkers { event.syncMarker = nil }
                return (event.id, event)
            }, uniquingKeysWith: { first, _ in first })
        }
    }
}

private func systemCheckDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

func testSystemAllDayEndRepresentations() throws {
    let zone = TimeZone(identifier: "Asia/Seoul")!
    let start = systemCheckDate("2026-09-30T00:00:00+09:00")
    let expected = CalendarEventTime.allDay(startDate: "2026-09-30", exclusiveEndDate: "2026-10-01")
    require(try SystemCalendarSafety.allDayTime(start: start,
        end: systemCheckDate("2026-09-30T23:59:59+09:00"), timeZone: zone) == expected,
        "macOS final-second end must become an exclusive next-day date")
    require(try SystemCalendarSafety.allDayTime(start: start,
        end: systemCheckDate("2026-10-01T00:00:00+09:00"), timeZone: zone) == expected,
        "already-exclusive midnight must not gain an extra day")
    require(try SystemCalendarSafety.allDayTime(start: start,
        end: systemCheckDate("2026-10-02T23:59:59+09:00"), timeZone: zone) ==
        .allDay(startDate: "2026-09-30", exclusiveEndDate: "2026-10-03"),
        "multi-day events must preserve the final included day")
    for end in [start, start.addingTimeInterval(-1)] {
        do {
            _ = try SystemCalendarSafety.allDayTime(start: start, end: end, timeZone: zone)
            require(false, "invalid raw intervals must not be guessed into one-day events")
        } catch SystemCalendarError.invalidDate {}
    }
}

func testSystemAllDayDSTAndWriteRoundTrip() throws {
    let zone = TimeZone(identifier: "America/New_York")!
    for (start, end, first, last) in [
        ("2026-03-08T00:00:00-05:00", "2026-03-08T23:59:59-04:00", "2026-03-08", "2026-03-09"),
        ("2026-11-01T00:00:00-04:00", "2026-11-01T23:59:59-05:00", "2026-11-01", "2026-11-02")
    ] {
        require(try SystemCalendarSafety.allDayTime(start: systemCheckDate(start),
            end: systemCheckDate(end), timeZone: zone) == .allDay(startDate: first, exclusiveEndDate: last),
            "23-hour and 25-hour days must preserve calendar dates")
    }
    for time in [CalendarEventTime.allDay(startDate: "2026-09-30", exclusiveEndDate: "2026-10-01"),
                 .allDay(startDate: "2026-09-30", exclusiveEndDate: "2026-10-03"),
                 .allDay(startDate: "2026-03-08", exclusiveEndDate: "2026-03-09"),
                 .allDay(startDate: "2026-11-01", exclusiveEndDate: "2026-11-02")] {
        let (start, end) = try SystemCalendarSafety.eventKitDates(for: time)
        require(try SystemCalendarSafety.allDayTime(start: start, end: end) == time,
                "macOS all-day write/read must preserve one-day and multi-day durations")
    }
    let timed = sample("timed").content.time
    let (start, end) = try SystemCalendarSafety.eventKitDates(for: timed)
    require(CalendarEventTime.timed(start: start, end: end, timeZoneID: "Asia/Seoul") == timed,
            "timed event endpoints must remain unchanged")
}

func testSystemLegacyEmptyAllDayJournalRecovery() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daouBackend = FakeSystemCalendarBackend()
        let googleBackend = FakeSystemCalendarBackend()
        var source = sample("external:all-day", title: "종일 일정")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        source.content.time = try SystemCalendarSafety.allDayTime(start: start, end: end)
        googleBackend.insert(source)
        daouBackend.insert(sample("external:healthy", title: "다우 정상 일정"))
        let marker = UUID().uuidString
        var oldContent = source.content
        guard case let .allDay(first, _) = oldContent.time else { return }
        oldContent.time = .allDay(startDate: first, exclusiveEndDate: first)
        var state = try await store.load()
        state.mappings[marker] = CalendarMapping(id: marker, daouEventID: nil,
                                               googleEventID: source.id, baseline: nil)
        state.pendingOperations[marker] = PendingSyncOperation(id: marker,
            operation: .create(mappingID: marker, target: .daou, sourceEventID: source.id, content: oldContent),
            newBaseline: .content(oldContent))
        try await store.save(state)
        let coordinator = SyncCoordinator(store: store,
            daou: SystemCalendarProvider(side: .daou, backend: daouBackend),
            google: SystemCalendarProvider(side: .google, backend: googleBackend))
        let run = try await coordinator.run(allowWrites: true)
        let recovered = try await store.load()
        require(run.completed == 2 && recovered.pendingOperations.isEmpty,
                "provably unwritten legacy interval must replan from fresh source and allow both directions")
        require(daouBackend.writes() == 1 && googleBackend.writes() == 1,
                "legacy recovery must create exactly one copy per source")
        let settled = try await coordinator.run(allowWrites: true)
        require(settled.completed == 0 && settled.held == 0,
                "all-day baseline must settle without duplicate or repeated updates")
    }
}

func testSystemUncertainJournalDoesNotBlockHealthyMappings() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daouBackend = FakeSystemCalendarBackend()
        let googleBackend = FakeSystemCalendarBackend()
        let source = sample("external:uncertain", title: "저장 불확실")
        googleBackend.insert(source)
        googleBackend.insert(sample("external:google-healthy", title: "Google 정상 일정"))
        daouBackend.insert(sample("external:daou-healthy", title: "다우 정상 일정"))
        let marker = UUID().uuidString
        var state = try await store.load()
        state.mappings[marker] = CalendarMapping(id: marker, daouEventID: nil,
                                               googleEventID: source.id, baseline: nil)
        state.pendingOperations[marker] = PendingSyncOperation(id: marker,
            operation: .create(mappingID: marker, target: .daou, sourceEventID: source.id, content: source.content),
            newBaseline: .content(source.content))
        try await store.save(state)
        let coordinator = SyncCoordinator(store: store,
            daou: SystemCalendarProvider(side: .daou, backend: daouBackend),
            google: SystemCalendarProvider(side: .google, backend: googleBackend))
        let run = try await coordinator.run(allowWrites: true)
        require(run.completed == 2 && run.held == 1, "uncertain journal must hold only its own mapping")
        require((try await store.load()).pendingOperations[marker] != nil && daouBackend.writes() == 1,
                "uncertain create must preserve its journal and never be blindly replayed")
        let repeatRun = try await coordinator.run(allowWrites: true)
        require(repeatRun.completed == 0 && repeatRun.held == 1 && daouBackend.writes() == 1,
                "repeated cycles must keep uncertainty held without blocking or duplicating healthy copies")
    }
}

func testSystemNewDateFailureDoesNotBlockHealthyMappings() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daouBackend = FakeSystemCalendarBackend()
        let googleBackend = FakeSystemCalendarBackend()
        googleBackend.insert(sample("external:invalid", title: "날짜 거절 일정"))
        googleBackend.insert(sample("external:healthy", title: "정상 일정"))
        daouBackend.rejectDate(forTitle: "날짜 거절 일정")
        let coordinator = SyncCoordinator(store: store,
            daou: SystemCalendarProvider(side: .daou, backend: daouBackend),
            google: SystemCalendarProvider(side: .google, backend: googleBackend))
        let run = try await coordinator.run(allowWrites: true)
        require(run.completed == 1 && run.held == 1 && daouBackend.writes() == 1,
                "a newly rejected date must not abort other writes in the same cycle")
        require((try await store.load()).pendingOperations.count == 1,
                "failed write must remain journaled until its outcome is verified")
    }
}

func testSystemMissingIsNotDeletion() async throws {
    let backend = FakeSystemCalendarBackend()
    let provider = SystemCalendarProvider(side: .daou, backend: backend)
    require(try await provider.observe(eventID: "missing") == .unavailable(.unknown),
            "EventKit missing ID must never be a tombstone")
    backend.hideCalendar()
    do {
        _ = try await provider.observe(eventID: "missing")
        require(false, "missing calendar must fail instead of returning deletion")
    } catch SystemCalendarError.calendarMissing {}
}

func testSystemCreateRecoveryAcrossProviderInstances() async throws {
    let backend = FakeSystemCalendarBackend()
    let marker = UUID().uuidString
    let operation = SyncOperation.create(mappingID: marker, target: .google,
        sourceEventID: "source", content: sample("source").content)
    backend.loseCreateReply()
    do {
        _ = try await SystemCalendarProvider(side: .google, backend: backend).apply(operation)
        require(false, "lost create reply should fail")
    } catch CalendarHTTPError.responseMissing {}
    let receipt = try await SystemCalendarProvider(side: .google, backend: backend).recover(operation)
    require(receipt.eventID == "sync:" + marker && backend.writes() == 1,
            "new provider must recover saved marker without duplicate create")
}

func testSystemAmbiguousCreateNeverReplays() async throws {
    let backend = FakeSystemCalendarBackend()
    let operation = SyncOperation.create(mappingID: UUID().uuidString, target: .google,
        sourceEventID: "source", content: sample("source").content)
    do {
        _ = try await SystemCalendarProvider(side: .google, backend: backend).recover(operation)
        require(false, "missing marker must hold uncertain create")
    } catch SystemCalendarError.uncertainWrite {}
    require(backend.writes() == 0, "uncertain create must never write")
}

func testSystemDuplicateMarkerHolds() async throws {
    let backend = FakeSystemCalendarBackend()
    let marker = UUID().uuidString
    let first = sample("sync:" + marker, marker: marker)
    backend.insert(first)
    backend.insertPhysicalDuplicate(first)
    do {
        _ = try await SystemCalendarProvider(side: .google, backend: backend).apply(
            .create(mappingID: marker, target: .google, sourceEventID: "source", content: sample("s").content))
        require(false, "duplicate markers must fail closed")
    } catch SystemCalendarError.uncertainWrite {}
    require(backend.writes() == 0, "duplicate marker must not create another copy")
    do {
        _ = try await SystemCalendarProvider(side: .google, backend: backend).fetchChanges(cursor: nil, pageToken: nil)
        require(false, "full snapshot must not collapse physically distinct copies with same logical ID")
    } catch SystemCalendarError.uncertainWrite {}
}

func testSystemSnapshotAndMissingSafetyThroughCoordinator() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daouBackend = FakeSystemCalendarBackend()
        let googleBackend = FakeSystemCalendarBackend()
        let source = sample("external:source")
        daouBackend.insert(source)
        let coordinator = SyncCoordinator(store: store,
            daou: SystemCalendarProvider(side: .daou, backend: daouBackend),
            google: SystemCalendarProvider(side: .google, backend: googleBackend))
        let first = try await coordinator.run(allowWrites: true)
        require(first.completed == 1, "full system snapshot without cursor should apply")
        let second = try await coordinator.run(allowWrites: true)
        require(second.completed == 0, "system repeat run should be settled")
        daouBackend.removeAll()
        let missing = try await coordinator.run(allowWrites: true)
        let state = try await store.load()
        require(state.daouObserved.isEmpty && state.googleCursor == nil,
                "full system snapshot must replace stale cache without cursors")
        require(missing.held == 1 && missing.completed == 0 && googleBackend.writes() == 1,
                "missing source must hold peer, not delete or duplicate it")
    }
}

func testSystemJournalRecoveryThroughCoordinator() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daouBackend = FakeSystemCalendarBackend()
        let googleBackend = FakeSystemCalendarBackend()
        daouBackend.insert(sample("external:source"))
        googleBackend.loseCreateReply()
        let coordinator = SyncCoordinator(store: store,
            daou: SystemCalendarProvider(side: .daou, backend: daouBackend),
            google: SystemCalendarProvider(side: .google, backend: googleBackend))
        do { _ = try await coordinator.run(allowWrites: true) }
        catch CalendarHTTPError.responseMissing {}
        require((try await store.load()).pendingOperations.count == 1, "lost system create must stay journaled")
        _ = try await coordinator.run(allowWrites: true)
        let recovered = try await store.load()
        require(googleBackend.writes() == 1 && recovered.pendingOperations.isEmpty,
                "journal recovery must use provider recovery and avoid replay")
    }
}

func testSystemCanonicalVersionAndMarker() throws {
    let content = CalendarEventContent(title: "Team", time: .allDay(
        startDate: "2026-09-30", exclusiveEndDate: "2026-10-01"))
    let version = try SystemCalendarSafety.version(content: content, modified: nil)
    require(version == "83058ede55bdac12bf9c83bc220b9517e306da0ce42531ee629faef49fc8a83e", "version must be stable across fresh encoders and processes")
    let marker = UUID().uuidString
    require(try SystemCalendarSafety.marker(from: SystemCalendarSafety.markerURL(marker.lowercased())) == marker,
            "marker normalizes UUID case")
    require(SystemCalendarSafety.marker(from: URL(string: "https://example.com/")) == nil,
            "foreign URL must not link events")
    require(SystemCalendarSafety.marker(from: URL(string: "happylulu://sync/" + marker + "?extra=1")) == nil,
            "noncanonical marker must not link events")
    var empty = content
    empty.notes = ""
    empty.location = ""
    require(SystemCalendarSafety.normalized(empty) == content, "empty fields normalize before baseline comparison")
    require(SystemCalendarSafety.eventID(marker: marker, externalID: "server-uid", localID: "local-id") == "external:server-uid",
            "server UID must take precedence so copied events can be found outside listing bounds")
}

func testSystemExternalIDUpgradeAndOutsideWindowEdit() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daouBackend = FakeSystemCalendarBackend()
        let googleBackend = FakeSystemCalendarBackend()
        let source = sample("external:source")
        daouBackend.insert(source)
        let coordinator = SyncCoordinator(store: store,
            daou: SystemCalendarProvider(side: .daou, backend: daouBackend),
            google: SystemCalendarProvider(side: .google, backend: googleBackend))
        _ = try await coordinator.run(allowWrites: true)
        googleBackend.assignExternalIDsToCopies()
        _ = try await coordinator.run(allowWrites: true)
        let state = try await store.load()
        guard let mapping = state.mappings.values.first, let targetID = mapping.googleEventID,
              var copy = try googleBackend.event(id: targetID) else {
            require(false, "copy mapping must exist")
            return
        }
        require(targetID.hasPrefix("external:"), "provisional marker ID must upgrade when server UID appears")
        let future = Date().addingTimeInterval(730 * 86_400)
        copy.content.time = .timed(start: future, end: future.addingTimeInterval(3600), timeZoneID: "Asia/Seoul")
        copy.content.title = "멀리 옮긴 일정"
        copy.syncMarker = nil
        copy.version = "remote-v3"
        googleBackend.insert(copy)
        let outside = try await coordinator.run(allowWrites: true)
        let changedSource = try daouBackend.event(id: source.id)
        require(outside.completed == 1 && changedSource?.content == copy.content,
                "server UID must resolve and copy a moved event even outside full-snapshot bounds and without URL")
        let settled = try await coordinator.run(allowWrites: true)
        require(settled.completed == 0 && settled.held == 0, "mapped outside-window events remain settled")
    }
}

func testSystemConfigurationBackwardsDecode() throws {
    var state = CalendarSyncState()
    state.configuration.googleCalendarID = "g"
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(CalendarSyncState.self, from: data)
    require(decoded.configuration.systemAccountsConfirmed == nil && decoded.configuration.googleCalendarID == "g",
            "old state without account confirmation must decode and require explicit confirmation")
}

func testSystemMarkerLostBeforeUIDUpgradeNeverCopiesBack() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daouBackend = FakeSystemCalendarBackend()
        let googleBackend = FakeSystemCalendarBackend()
        daouBackend.insert(sample("external:source"))
        let coordinator = SyncCoordinator(store: store,
            daou: SystemCalendarProvider(side: .daou, backend: daouBackend),
            google: SystemCalendarProvider(side: .google, backend: googleBackend))
        _ = try await coordinator.run(allowWrites: true)
        googleBackend.assignExternalIDsToCopies(removeMarkers: true)
        let beforeCount = (try await store.load()).mappings.count
        let run = try await coordinator.run(allowWrites: true)
        require(run.completed == 0 && run.held == 1 && daouBackend.writes() == 0,
                "marker lost before UID upgrade must hold, never import copy back to source")
        require((try await store.load()).mappings.count == beforeCount,
                "unverified copy must not seed a second mapping")
    }
}
func testDisplayReadSelectionAndRangeBoundaries() async throws {
    let access = SystemCalendarAccess()
    let start = Date(timeIntervalSince1970: 1_791_806_400)
    let events = try await access.displayEvents(calendarIDs: [], start: start, end: start.addingTimeInterval(3600))
    require(events.isEmpty, "No selected calendars must not query all account events")
    do {
        _ = try await access.displayEvents(calendarIDs: ["unused-fixture-calendar"], start: start, end: start)
        require(false, "Invalid range must fail before EventKit queries")
    } catch SystemCalendarError.invalidDate {}
}
