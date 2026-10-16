import Foundation
import CalendarSyncCore
@testable import CalendarSyncServices

func require(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
        exit(1)
    }
}

func sample(_ id: String, title: String = "팀 회의", marker: String? = nil) -> CalendarEvent {
    let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 3600)
    return CalendarEvent(id: id, version: "v1",
        content: CalendarEventContent(title: title,
            time: .timed(start: start, end: start.addingTimeInterval(3600), timeZoneID: "Asia/Seoul"),
            notes: "준비", location: "회의실"), syncMarker: marker)
}

actor FakeProvider: CalendarProvider {
    nonisolated let side: CalendarSide
    private var events: [String: CalendarEvent]
    private(set) var writes = 0
    private var loseOneCreateReply = false
    private var loseOneDeleteReply = false
    private var hiddenFromList = false
    private var unavailableOnMissing = false
    private var fetchHold: CheckedContinuation<Void, Never>?
    private var holdNextFetch = false
    private var fetchStarted = false
    private var fetchError: Error?
    private var recoveryError: SystemCalendarError?
    private var applyError: SystemCalendarError?

    init(side: CalendarSide, events: [CalendarEvent] = []) {
        self.side = side
        self.events = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
    }

    func pauseFetch() { holdNextFetch = true }
    func isFetchHeld() -> Bool { fetchStarted && fetchHold != nil }
    func resumeFetch() { fetchHold?.resume(); fetchHold = nil }
    func setLostReply() { loseOneCreateReply = true }
    func setLostDeleteReply() { loseOneDeleteReply = true }
    func setHiddenFromList() { hiddenFromList = true }
    func setUnavailableOnMissing() { unavailableOnMissing = true }
    func setFetchError(_ error: Error?) { fetchError = error }
    func setRecoveryError(_ error: SystemCalendarError?) { recoveryError = error }
    func setApplyError(_ error: SystemCalendarError?) { applyError = error }
    func replace(_ event: CalendarEvent) { events[event.id] = event }
    func remove(_ id: String) { events.removeValue(forKey: id) }
    func count() -> Int { events.count }
    func items() -> [CalendarEvent] { Array(events.values) }

    func fetchChanges(cursor: String?, pageToken: String?) async throws -> CalendarChangePage {
        if holdNextFetch {
            holdNextFetch = false; fetchStarted = true
            await withCheckedContinuation { fetchHold = $0 }
        }
        if let fetchError { throw fetchError }
        return CalendarChangePage(changes: hiddenFromList ? [] : events.values.map(CalendarChange.upsert),
                                  nextCursor: side == .google ? "next" : nil,
                                  isFullSnapshot: side == .daou)
    }

    func observe(eventID: String) async throws -> CalendarObservation {
        if let event = events[eventID] { return .present(event) }
        return unavailableOnMissing ? .unavailable(.permissionDenied) : .confirmedDeleted
    }

    func apply(_ operation: SyncOperation) async throws -> CalendarWriteReceipt {
        if let applyError { throw applyError }
        switch operation {
        case let .create(mappingID, target, _, content):
            require(target == side, "fake wrong target")
            let id = "\(side.rawValue):\(mappingID)"
            if let existing = events[id] {
                return CalendarWriteReceipt(eventID: id, version: existing.version)
            }
            let event = CalendarEvent(id: id, version: "v1", content: content, syncMarker: mappingID)
            events[id] = event
            writes += 1
            if loseOneCreateReply {
                loseOneCreateReply = false
                throw CalendarHTTPError.responseMissing
            }
            return CalendarWriteReceipt(eventID: id, version: event.version)
        case let .update(_, target, id, expected, content):
            require(target == side, "fake wrong target")
            guard var existing = events[id], existing.version == expected else {
                throw CalendarProviderError.targetChanged
            }
            existing.content = content
            existing.version = "v\(writes + 2)"
            events[id] = existing
            writes += 1
            return CalendarWriteReceipt(eventID: id, version: existing.version)
        case let .delete(_, target, id, expected):
            require(target == side, "fake wrong target")
            guard let existing = events[id], existing.version == expected else {
                throw CalendarProviderError.targetChanged
            }
            events.removeValue(forKey: id)
            writes += 1
            if loseOneDeleteReply {
                loseOneDeleteReply = false
                throw CalendarHTTPError.responseMissing
            }
            return CalendarWriteReceipt(eventID: id, version: nil)
        }
    }

    func recover(_ operation: SyncOperation) async throws -> CalendarWriteReceipt {
        if let recoveryError { throw recoveryError }
        return try await apply(operation)
    }
}

func withStore(_ run: (SyncStore) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HappyLulu-calendar-check-\(UUID())")
    let store = try SyncStore(url: folder.appendingPathComponent("sync.sqlite"))
    try await run(store)
    try? FileManager.default.removeItem(at: folder)
}

func configured(_ store: SyncStore, enabled: Bool = false) async throws {
    var state = CalendarSyncState()
    state.configuration.daouCalendarURL = "https://example.daouoffice.com/calendar/own/"
    state.configuration.googleCalendarID = "test@example.com"
    state.configuration.enabled = enabled
    state.configuration.previewAccepted = enabled
    try await store.save(state)
}

func testCancelledSyncDoesNotStartLaterWrites() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let before = try JSONEncoder().encode(await store.load())
        let daou = FakeProvider(side: .daou, events: [sample("cancelled")])
        let google = FakeProvider(side: .google)
        await daou.pauseFetch()
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        let task = Task { try await coordinator.run(allowWrites: true) }
        while !(await daou.isFetchHeld()) { await Task.yield() }
        task.cancel()
        await daou.resumeFetch()
        do { _ = try await task.value; require(false, "Cancelled sync must stop") }
        catch is CancellationError {}
        let writes = await google.writes
        require(writes == 0, "Disabling during fetch must prevent later calendar writes")
        let after = try await store.load()
        let decodedBefore = try JSONDecoder().decode(CalendarSyncState.self, from: before)
        require(after.mappings.count == decodedBefore.mappings.count && after.pendingOperations.isEmpty
            && after.lastErrorCode == nil && after.consecutiveFailures == 0,
            "Cancellation must preserve the existing ledger without recording a retry failure")
    }
}

func testPreviewAndBothDirections() async throws {
    try await withStore { store in
        try await configured(store)
        let daou = FakeProvider(side: .daou, events: [sample("d1", title: "다우 일정")])
        let google = FakeProvider(side: .google, events: [sample("g1", title: "Google 일정")])
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        let preview = try await coordinator.run(allowWrites: false)
        require(preview.toDaou == 1 && preview.toGoogle == 1, "both-direction preview")
        let previewDaouCount = await daou.count()
        let previewGoogleCount = await google.count()
        require(previewDaouCount == 1 && previewGoogleCount == 1, "preview must be read-only")
        var state = try await store.load()
        state.configuration.enabled = true
        state.configuration.previewAccepted = true
        try await store.save(state)
        let applied = try await coordinator.run(allowWrites: true)
        require(applied.completed == 2, "both directions should apply")
        let finalDaouCount = await daou.count()
        let finalGoogleCount = await google.count()
        require(finalDaouCount == 2 && finalGoogleCount == 2, "each side should contain both events")
        let repeatRun = try await coordinator.run(allowWrites: true)
        require(repeatRun.completed == 0, "second run should be idempotent")
        require((try await store.load()).pendingOperations.isEmpty, "journal should clear")
    }
}

func testFirstSystemWriteRequiresMatchingPreview() async throws {
    try await withStore { store in
        var state = CalendarSyncState()
        state.configuration.daouBaseURL = "eventkit"
        state.configuration.daouCalendarURL = "daou-calendar"
        state.configuration.googleCalendarID = "google-calendar"
        state.configuration.systemAccountsConfirmed = true
        try await store.save(state)
        let daou = FakeProvider(side: .daou, events: [sample("d1", title: "처음 제목")])
        let google = FakeProvider(side: .google)
        let previewer = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await previewer.run(allowWrites: false)
        state = try await store.load()
        require(state.initialPreviewFingerprint != nil, "preview should persist an exact observed snapshot")
        state.configuration.enabled = true
        state.configuration.previewAccepted = true
        try await store.save(state)
        await daou.replace(sample("d1", title: "미리보기 후 변경한 제목"))
        let restarted = SyncCoordinator(store: store, daou: daou, google: google)
        do {
            _ = try await restarted.run(allowWrites: true)
            require(false, "changed content must stop first write")
        } catch SyncCoordinatorError.previewChanged {}
        require(await google.writes == 0, "stale preview must perform no calendar write")
        state = try await store.load()
        require(!state.configuration.enabled && !state.configuration.previewAccepted &&
                state.initialPreviewFingerprint == nil && state.lastPreview == nil,
                "stale preview must require a fresh explicit review")
        _ = try await restarted.run(allowWrites: false)
        state = try await store.load()
        state.configuration.enabled = true
        state.configuration.previewAccepted = true
        try await store.save(state)
        let applied = try await restarted.run(allowWrites: true)
        let completedWrites = await google.writes
        require(applied.completed == 1 && completedWrites == 1,
                "fresh unchanged preview may start first sync")
    }
}

func testOldSystemPreviewWithoutFingerprintCannotWrite() async throws {
    try await withStore { store in
        var state = CalendarSyncState()
        state.configuration.daouBaseURL = "eventkit"
        state.configuration.daouCalendarURL = "daou-calendar"
        state.configuration.googleCalendarID = "google-calendar"
        state.configuration.systemAccountsConfirmed = true
        state.configuration.enabled = true
        state.configuration.previewAccepted = true
        state.lastPreview = SyncRunSummary()
        try await store.save(state)
        let daou = FakeProvider(side: .daou, events: [sample("d1")])
        let google = FakeProvider(side: .google)
        do {
            _ = try await SyncCoordinator(store: store, daou: daou, google: google).run(allowWrites: true)
            require(false, "legacy count-only preview must not permit writes")
        } catch SyncCoordinatorError.previewChanged {}
        require(await google.writes == 0, "legacy preview must write nothing")
    }
}

func testFirstSystemSyncJournalRecoveryBypassesFreshPreviewGate() async throws {
    try await withStore { store in
        var state = CalendarSyncState()
        state.configuration.daouBaseURL = "eventkit"
        state.configuration.daouCalendarURL = "daou-calendar"
        state.configuration.googleCalendarID = "google-calendar"
        state.configuration.systemAccountsConfirmed = true
        try await store.save(state)
        let daou = FakeProvider(side: .daou, events: [sample("d1")])
        let google = FakeProvider(side: .google)
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await coordinator.run(allowWrites: false)
        state = try await store.load()
        state.configuration.enabled = true
        state.configuration.previewAccepted = true
        try await store.save(state)
        await google.setLostReply()
        do {
            _ = try await coordinator.run(allowWrites: true)
            require(false, "lost first receipt should leave a journal")
        } catch CalendarHTTPError.responseMissing {}
        state = try await store.load()
        require(state.initialWriteAuthorized == true && state.pendingOperations.count == 1,
                "first write approval must survive a pending journal")
        let resumed = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await resumed.run(allowWrites: true)
        let writes = await google.writes
        let recoveredState = try await store.load()
        require(writes == 1 && recoveredState.pendingOperations.isEmpty,
                "resume should recover one existing copy without replay")
    }
}

func testUncertainFirstPendingHoldsNewlyDiscoveredEvent() async throws {
    try await withStore { store in
        var state = CalendarSyncState()
        state.configuration.daouBaseURL = "eventkit"
        state.configuration.daouCalendarURL = "daou-calendar"
        state.configuration.googleCalendarID = "google-calendar"
        state.configuration.systemAccountsConfirmed = true
        try await store.save(state)
        let first = sample("d1", title: "미리 본 일정 A")
        let daou = FakeProvider(side: .daou, events: [first])
        let google = FakeProvider(side: .google)
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await coordinator.run(allowWrites: false)
        state = try await store.load()
        let id = state.mappings.keys.first!
        state.configuration.enabled = true
        state.configuration.previewAccepted = true
        state.initialWriteAuthorized = true
        state.pendingOperations[id] = PendingSyncOperation(id: id,
            operation: .create(mappingID: id, target: .google, sourceEventID: first.id, content: first.content),
            newBaseline: .content(first.content))
        try await store.save(state) // Crash after journal save, before EventKit.apply.
        await google.setRecoveryError(.uncertainWrite)
        await daou.replace(sample("d2", title: "미리 보지 않은 일정 B"))
        let held = try await SyncCoordinator(store: store, daou: daou, google: google).run(allowWrites: true)
        let writes = await google.writes
        require(held.held == 1 && writes == 0,
                "uncertain first journal must hold all new writes")
        state = try await store.load()
        require(state.lastSuccessAt == nil && state.pendingOperations.count == 1,
                "uncertain first journal must not mark initial sync successful")
    }
}

func testUnwrittenFirstPendingRechecksPreviewBeforeNewEvent() async throws {
    try await withStore { store in
        var state = CalendarSyncState()
        state.configuration.daouBaseURL = "eventkit"
        state.configuration.daouCalendarURL = "daou-calendar"
        state.configuration.googleCalendarID = "google-calendar"
        state.configuration.systemAccountsConfirmed = true
        try await store.save(state)
        let first = sample("d1", title: "미리 본 일정 A")
        let daou = FakeProvider(side: .daou, events: [first])
        let google = FakeProvider(side: .google)
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await coordinator.run(allowWrites: false)
        state = try await store.load()
        let id = state.mappings.keys.first!
        state.configuration.enabled = true
        state.configuration.previewAccepted = true
        state.initialWriteAuthorized = true
        state.pendingOperations[id] = PendingSyncOperation(id: id,
            operation: .create(mappingID: id, target: .google, sourceEventID: first.id, content: first.content),
            newBaseline: .content(first.content))
        try await store.save(state)
        await google.setRecoveryError(.writeNotAttempted)
        await daou.replace(sample("d2", title: "미리 보지 않은 일정 B"))
        do {
            _ = try await SyncCoordinator(store: store, daou: daou, google: google).run(allowWrites: true)
            require(false, "a discarded unwritten journal must recheck preview")
        } catch SyncCoordinatorError.previewChanged {}
        require(await google.writes == 0, "new event B must not be copied")
    }
}

func testUncertainFirstApplyDoesNotRecordSuccess() async throws {
    try await withStore { store in
        var state = CalendarSyncState()
        state.configuration.daouBaseURL = "eventkit"
        state.configuration.daouCalendarURL = "daou-calendar"
        state.configuration.googleCalendarID = "google-calendar"
        state.configuration.systemAccountsConfirmed = true
        try await store.save(state)
        let daou = FakeProvider(side: .daou, events: [sample("d1")])
        let google = FakeProvider(side: .google)
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await coordinator.run(allowWrites: false)
        state = try await store.load()
        state.configuration.enabled = true
        state.configuration.previewAccepted = true
        try await store.save(state)
        await google.setApplyError(.uncertainWrite)
        let result = try await coordinator.run(allowWrites: true)
        state = try await store.load()
        require(result.held >= 1 && state.lastSuccessAt == nil && !state.pendingOperations.isEmpty,
                "an uncertain first apply cannot establish initial success")
    }
}

func testFreshPreviewAfterReceiptBeforeFirstSuccess() async throws {
    try await withStore { store in
        var state = CalendarSyncState()
        state.configuration.daouBaseURL = "eventkit"
        state.configuration.daouCalendarURL = "daou-calendar"
        state.configuration.googleCalendarID = "google-calendar"
        state.configuration.systemAccountsConfirmed = true
        try await store.save(state)
        let daou = FakeProvider(side: .daou, events: [sample("d1")])
        let google = FakeProvider(side: .google)
        let first = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await first.run(allowWrites: false)
        state = try await store.load()
        let oldFingerprint = state.initialPreviewFingerprint
        state.configuration.enabled = true
        state.configuration.previewAccepted = true
        try await store.save(state)
        _ = try await first.run(allowWrites: true)
        state = try await store.load()
        require(state.pendingOperations.isEmpty && state.initialWriteAuthorized == true,
                "first receipt must have been journaled and completed")
        state.lastSuccessAt = nil // Simulate exit after receipt persistence, before final success marker.
        try await store.save(state)
        await daou.replace(sample("d2", title: "새 미리보기 일정"))
        let restarted = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await restarted.run(allowWrites: false)
        state = try await store.load()
        require(state.initialPreviewFingerprint != nil &&
                state.initialPreviewFingerprint != oldFingerprint &&
                state.initialWriteAuthorized == nil,
                "explicit preview after restart must replace old approval snapshot")
        state.configuration.enabled = true
        state.configuration.previewAccepted = true
        try await store.save(state)
        _ = try await restarted.run(allowWrites: true)
        require(await google.count() == 2, "freshly previewed event should sync")
    }
}

func testInitialDuplicateHold() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let same = sample("d1")
        let googleCopy = CalendarEvent(id: "g1", version: "v1", content: same.content)
        let daou = FakeProvider(side: .daou, events: [same])
        let google = FakeProvider(side: .google, events: [googleCopy])
        let summary = try await SyncCoordinator(store: store, daou: daou, google: google).run(allowWrites: true)
        require(summary.completed == 0 && summary.conflicts == 2, "duplicate candidates must hold")
        let daouCount = await daou.count()
        let googleCount = await google.count()
        require(daouCount == 1 && googleCount == 1, "must not copy suspected duplicates")
    }
}

func testInitialDuplicateCanBeResolved() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daouEvent = sample("d1")
        var googleEvent = CalendarEvent(id: "g1", version: "v1", content: daouEvent.content)
        googleEvent.content.notes = "Google 쪽 설명"
        let daou = FakeProvider(side: .daou, events: [daouEvent])
        let google = FakeProvider(side: .google, events: [googleEvent])
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await coordinator.run(allowWrites: true)
        let state = try await store.load()
        guard let conflictID = state.conflicts.keys.sorted().first else {
            require(false, "duplicate conflict should exist")
            return
        }
        try await coordinator.resolveConflict(mappingID: conflictID, prefer: .daou)
        let resolved = try await store.load()
        require(resolved.mappings.count == 1 && resolved.conflicts.isEmpty, "duplicate mappings should merge")
        require((await google.items()).first?.content == daouEvent.content, "chosen Daou content should update Google")
    }
}

func testConflictRequiresApprovalAndFreshSnapshot() async throws {
    try await withStore { store in
        try await configured(store)
        let d = sample("d1")
        var g = CalendarEvent(id: "g1", version: "v1", content: d.content)
        g.content.notes = "Google original"
        let daou = FakeProvider(side: .daou, events: [d])
        let google = FakeProvider(side: .google, events: [g])
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await coordinator.run(allowWrites: false)
        let preview = try await store.load()
        let id = preview.conflicts.keys.sorted().first!
        for mode in 0..<3 {
            var state = preview
            state.configuration.enabled = mode != 0
            state.configuration.previewAccepted = mode != 1
            if mode == 2 { state.configuration.daouBaseURL = "eventkit" }
            try await store.save(state)
            do {
                try await coordinator.resolveConflict(mappingID: id, prefer: .daou)
                require(false, "preview, paused, or unvalidated first cycle must not resolve")
            } catch SyncCoordinatorError.previewRequired {}
            let googleWrites = await google.writes
            let daouWrites = await daou.writes
            require(googleWrites == 0 && daouWrites == 0, "approval gate prevents writes")
            require((try await store.load()).pendingOperations.isEmpty, "approval gate leaves no journal")
        }
        var active = preview
        active.configuration.enabled = true
        active.configuration.previewAccepted = true
        try await store.save(active)
        _ = try await coordinator.run(allowWrites: true)
        g.content.notes = "New unseen edit"
        g.version = "v2"
        await google.replace(g)
        do {
            try await coordinator.resolveConflict(mappingID: id, prefer: .daou)
            require(false, "unseen changes must require a new conflict preview")
        } catch SyncCoordinatorError.conflictChanged {}
        require((await google.writes) == 0, "unseen edit must not be overwritten")
        require((try await store.load()).pendingOperations.isEmpty, "stale conflict leaves no journal")
        _ = try await coordinator.run(allowWrites: false)
        try await coordinator.resolveConflict(mappingID: id, prefer: .daou)
        require((await google.writes) == 1, "fresh approved conflict can resolve")
    }
}

func testSimultaneousEditCanBeResolved() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daou = FakeProvider(side: .daou, events: [sample("d1")])
        let google = FakeProvider(side: .google)
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await coordinator.run(allowWrites: true)
        guard let mapping = (try await store.load()).mappings.values.first,
              let daouID = mapping.daouEventID, let googleID = mapping.googleEventID,
              var d = (await daou.items()).first(where: { $0.id == daouID }),
              var g = (await google.items()).first(where: { $0.id == googleID }) else {
            require(false, "paired events should exist")
            return
        }
        d.content.title = "다우 수정"
        d.version = "v2"
        g.content.title = "Google 수정"
        g.version = "v2"
        await daou.replace(d)
        await google.replace(g)
        let conflicted = try await coordinator.run(allowWrites: true)
        require(conflicted.conflicts == 1, "simultaneous edits should conflict")
        try await coordinator.resolveConflict(mappingID: mapping.id, prefer: .google)
        require((await daou.items()).first(where: { $0.id == daouID })?.content.title == "Google 수정",
                "Google choice should update Daou")
        require((try await store.load()).conflicts.isEmpty, "resolved conflict should clear")
    }
}

func testLostCreateReplyDoesNotDuplicate() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daou = FakeProvider(side: .daou, events: [sample("d1")])
        let google = FakeProvider(side: .google)
        await google.setLostReply()
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        do {
            _ = try await coordinator.run(allowWrites: true)
            require(false, "lost reply should interrupt first run")
        } catch CalendarHTTPError.responseMissing {}
        require((try await store.load()).pendingOperations.count == 1, "operation must stay journaled")
        _ = try await coordinator.run(allowWrites: true)
        require(await google.count() == 1, "retry should reuse the same ID")
        require(await google.writes == 1, "remote create must happen once")
    }
}

func testListingGapDoesNotDelete() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daou = FakeProvider(side: .daou, events: [sample("d1")])
        let google = FakeProvider(side: .google)
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await coordinator.run(allowWrites: true)
        await daou.setHiddenFromList()
        let result = try await coordinator.run(allowWrites: true)
        require(result.completed == 0, "missing listing item is not a tombstone")
        require(await google.count() == 1, "peer must remain")
    }
}

func testLostDeleteReplyCompletesRecovery() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daou = FakeProvider(side: .daou, events: [sample("d1")])
        let google = FakeProvider(side: .google)
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        _ = try await coordinator.run(allowWrites: true)
        await daou.remove("d1")
        await google.setLostDeleteReply()
        do {
            _ = try await coordinator.run(allowWrites: true)
            require(false, "lost delete reply should interrupt the first run")
        } catch CalendarHTTPError.responseMissing {}
        require((try await store.load()).pendingOperations.count == 1, "delete should remain journaled")
        _ = try await coordinator.run(allowWrites: true)
        require(await google.count() == 0, "already deleted peer should stay deleted")
        require((try await store.load()).pendingOperations.isEmpty, "delete journal should clear")
    }
}

func testAuthenticationFailurePausesSchedule() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daou = FakeProvider(side: .daou)
        let google = FakeProvider(side: .google)
        await daou.setFetchError(CalendarHTTPError.httpStatus(401, retryAfter: nil))
        do {
            _ = try await SyncCoordinator(store: store, daou: daou, google: google).run(allowWrites: true)
            require(false, "authentication failure should throw")
        } catch CalendarHTTPError.httpStatus(401, _) {}
        let state = try await store.load()
        require(!state.configuration.enabled && state.nextRunAt == nil, "authentication error should pause automatic retries")
    }
}

func testTransientFailureBackoff() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daou = FakeProvider(side: .daou)
        let google = FakeProvider(side: .google)
        await daou.setFetchError(CalendarHTTPError.responseMissing)
        let coordinator = SyncCoordinator(store: store, daou: daou, google: google)
        for expected in [60.0, 300.0] {
            do {
                _ = try await coordinator.run(allowWrites: true)
                require(false, "transient failure should throw")
            } catch CalendarHTTPError.responseMissing {}
            let state = try await store.load()
            let delay = state.nextRunAt?.timeIntervalSinceNow ?? 0
            require(delay > expected - 10 && delay <= expected + 2, "transient retry delay should back off")
            require(state.configuration.enabled, "transient error should not disable sync")
        }
    }
}

func testRetryAfterOverridesBackoff() async throws {
    try await withStore { store in
        try await configured(store, enabled: true)
        let daou = FakeProvider(side: .daou)
        let google = FakeProvider(side: .google)
        await daou.setFetchError(CalendarHTTPError.httpStatus(429, retryAfter: "120"))
        do {
            _ = try await SyncCoordinator(store: store, daou: daou, google: google).run(allowWrites: true)
            require(false, "rate limit should throw")
        } catch CalendarHTTPError.httpStatus(429, _) {}
        let delay = (try await store.load()).nextRunAt?.timeIntervalSinceNow ?? 0
        require(delay > 115 && delay <= 122, "Retry-After should override default backoff")
    }
}

func testICalendarPreservesUnknownProperties() throws {
    let event = sample("d1")
    let raw = try ICalendarCodec.create(event.content, mappingID: UUID().uuidString)
    let decoded = try ICalendarCodec.decode(raw, id: "d1", etag: "v1")
    require(decoded.content == event.content, "iCalendar round trip including timezone")
    let withUnknown = String(data: raw, encoding: .utf8)!
        .replacingOccurrences(of: "END:VEVENT", with: "X-EXTRA-FIELD:preserve-me\r\nEND:VEVENT")
    var changed = event.content
    changed.title = "새 제목, 줄 바꿈\n확인"
    let updated = try ICalendarCodec.update(Data(withUnknown.utf8), with: changed)
    require(String(data: updated, encoding: .utf8)!.contains("X-EXTRA-FIELD:preserve-me"), "unknown property preserved")
    require(try ICalendarCodec.decode(updated, id: "d1", etag: "v2").content == changed, "updated content")
}

func testGoogleCodecMarker() throws {
    let event = sample("g1")
    let marker = UUID().uuidString
    let json = try GoogleEventCodec.writeJSON(event.content, mappingID: marker, id: "g1")
    let decoded = try GoogleEventCodec.decode(GoogleEventResource(id: "g1", etag: "v1", status: "confirmed", json: json))
    require(decoded.content == event.content && decoded.syncMarker == marker, "Google managed fields and marker")
}

func testGoogleSlashTitleIsExcluded() throws {
    var content = sample("g1").content
    content.title = "기획/검토"
    let json = try GoogleEventCodec.writeJSON(content, mappingID: nil, id: "g1")
    let decoded = try GoogleEventCodec.decode(GoogleEventResource(
        id: "g1", etag: "v1", status: "confirmed", json: json))
    require(decoded.exclusion == .unsupportedProperties,
            "Daou-incompatible slash title should be excluded during preview")
}

let checks: [(String, () async throws -> Void)] = [
    ("cancelled sync prevents later writes", testCancelledSyncDoesNotStartLaterWrites),
    ("display read selection and range boundaries", testDisplayReadSelectionAndRangeBoundaries),
    ("preview preserves failure history", testSuccessfulPreviewKeepsFailureHistory),
    ("coordinator persists protected origin", testCoordinatorPersistsInvitationProtection),
    ("conflict protects invitation origin", testConflictCannotWriteProtectedInvitation),
    ("recovery protects invitation origin", testPendingRecoveryCannotWriteProtectedInvitation),
    ("expanded system alarms", { try testSystemExpandedAlarmSupport() }),
    ("expanded invitation protection", testSystemExpandedInvitationProtection),
    ("expanded recurrence occurrences", { try testSystemExpandedRecurrenceSupport() }),
    ("expanded recurrence copies", testSystemExpandedRecurrenceCopies),
    ("converted legacy series isolation", testSystemConvertedLegacySeriesIsolation),
    ("ambiguous pair sticky protection", { try await testAmbiguousPairPreservesProtectionAndJournal(pending: false) }),
    ("ambiguous pair pending journal", { try await testAmbiguousPairPreservesProtectionAndJournal(pending: true) }),
    ("summary preview versus applied run", testRunSummaryDistinguishesPreviewFromAppliedRun),
    ("summary excluded event reasons", testRunSummaryExplainsExcludedEvents),
    ("successful legacy system sync resume", testSuccessfulLegacySystemSyncCanResumeAfterFreshPreview),
    ("resume requires fresh same-pair review", { try testResumeRequiresFreshSamePairReview() }),
    ("initial start still requires fingerprint", { try testInitialSystemStartStillRequiresFingerprint() }),
    ("system all-day inclusive and exclusive ends", { try testSystemAllDayEndRepresentations() }),
    ("system all-day DST and write roundtrip", { try testSystemAllDayDSTAndWriteRoundTrip() }),
    ("system legacy empty all-day journal", testSystemLegacyEmptyAllDayJournalRecovery),
    ("system uncertain journal isolates mapping", testSystemUncertainJournalDoesNotBlockHealthyMappings),
    ("system date failure isolates mapping", testSystemNewDateFailureDoesNotBlockHealthyMappings),
    ("system missing ID safety", testSystemMissingIsNotDeletion),
    ("system create recovery across instances", testSystemCreateRecoveryAcrossProviderInstances),
    ("system ambiguous create hold", testSystemAmbiguousCreateNeverReplays),
    ("system duplicate marker hold", testSystemDuplicateMarkerHolds),
    ("system full snapshot and missing peer safety", testSystemSnapshotAndMissingSafetyThroughCoordinator),
    ("system journal recovery", testSystemJournalRecoveryThroughCoordinator),
    ("system canonical version and marker", { try testSystemCanonicalVersionAndMarker() }),
    ("system UID upgrade and outside-window edit", testSystemExternalIDUpgradeAndOutsideWindowEdit),
    ("system old configuration decode", { try testSystemConfigurationBackwardsDecode() }),
    ("system marker lost before UID upgrade", testSystemMarkerLostBeforeUIDUpgradeNeverCopiesBack),
    ("preview and bidirectional sync", testPreviewAndBothDirections),
    ("first system write matches preview", testFirstSystemWriteRequiresMatchingPreview),
    ("old system preview cannot write", testOldSystemPreviewWithoutFingerprintCannotWrite),
    ("first system journal recovery", testFirstSystemSyncJournalRecoveryBypassesFreshPreviewGate),
    ("uncertain first pending holds new event", testUncertainFirstPendingHoldsNewlyDiscoveredEvent),
    ("unwritten first pending rechecks preview", testUnwrittenFirstPendingRechecksPreviewBeforeNewEvent),
    ("uncertain first apply has no success", testUncertainFirstApplyDoesNotRecordSuccess),
    ("fresh preview after first receipt crash", testFreshPreviewAfterReceiptBeforeFirstSuccess),
    ("initial duplicate hold", testInitialDuplicateHold),
    ("initial duplicate resolution", testInitialDuplicateCanBeResolved),
    ("conflict approval and snapshot safety", testConflictRequiresApprovalAndFreshSnapshot),
    ("simultaneous edit resolution", testSimultaneousEditCanBeResolved),
    ("lost create reply retry", testLostCreateReplyDoesNotDuplicate),
    ("listing gap safety", testListingGapDoesNotDelete),
    ("lost delete reply recovery", testLostDeleteReplyCompletesRecovery),
    ("authentication failure pauses", testAuthenticationFailurePausesSchedule),
    ("transient failure backoff", testTransientFailureBackoff),
    ("Retry-After scheduling", testRetryAfterOverridesBackoff),
    ("iCalendar preserve and timezone", { try testICalendarPreservesUnknownProperties() }),
    ("Google event codec", { try testGoogleCodecMarker() }),
    ("Google slash title exclusion", { try testGoogleSlashTitleIsExcluded() })
]
for (name, check) in checks {
    do { try await check(); print("PASS \(name)") }
    catch {
        FileHandle.standardError.write(Data("FAIL \(name): \(error)\n".utf8))
        exit(1)
    }
}
print("\(checks.count) calendar service checks passed")
