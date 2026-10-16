import AppKit
import Combine
import Foundation
import Network
import CalendarSyncCore
import CalendarSyncServices

protocol CalendarSyncAccess: Sendable {
    func requestAccess() async throws
    func writableCalendars() async throws -> [SystemCalendarSummary]
}

extension SystemCalendarAccess: CalendarSyncAccess {}

private enum CalendarSyncModelError: Error, LocalizedError {
    case calendarPairLocked
    case sameCalendar
    case accountsNotConfirmed

    var errorDescription: String? {
        switch self {
        case .calendarPairLocked:
            "동기화를 시작한 뒤에는 캘린더 쌍을 바꿀 수 없습니다. 기존 중복 방지 기록을 보존하고 있어요."
        case .sameCalendar:
            "다우오피스와 Google에 서로 다른 캘린더를 선택해 주세요."
        case .accountsNotConfirmed:
            "서로 다른 다우오피스·Google 계정의 캘린더인지 확인해 주세요."
        }
    }
}

@MainActor
final class CalendarSyncModel: ObservableObject {
    @Published private(set) var calendars: [SystemCalendarSummary] = []
    @Published var selectedDaouCalendar = "" { didSet { invalidatePreview(oldValue != selectedDaouCalendar) } }
    @Published var selectedGoogleCalendar = "" { didSet { invalidatePreview(oldValue != selectedGoogleCalendar) } }
    @Published private(set) var preview: SyncRunSummary?
    @Published private(set) var conflicts: [SyncConflict] = []
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var nextRunAt: Date?
    @Published private(set) var lastFailureAt: Date?
    @Published private(set) var lastFailureCode: String?
    @Published private(set) var pauseReason: String?
    @Published private(set) var enabled = false
    @Published private(set) var isRunning = false {
        didSet {
            guard !isRunning, calendarRefreshPending else { return }
            calendarRefreshPending = false
            Task { await requestCalendarAccess(requestPermission: false) }
        }
    }
    @Published private(set) var calendarAccessReady = false
    @Published private(set) var pairLocked = false
    @Published var accountsConfirmed = false
    @Published var message: String?

    @Published private(set) var displayedEvents: [SystemCalendarDisplayEvent] = []
    @Published private(set) var isLoadingEvents = false
    @Published private(set) var eventReadError: String?
    @Published private(set) var eventsRevision = 0
    private var eventReadGeneration = 0
    private lazy var eventDisplayAccess = SystemCalendarAccess()

    private lazy var calendarAccess: any CalendarSyncAccess = SystemCalendarAccess()
    private let store: SyncStore?
    private let storeInitializationError: Error?
    private var timer: Timer?
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "HappyLulu.CalendarNetwork")
    private var loaded = false
    private(set) var runtimeAllowed = true
    private var runtimeGeneration = 0
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var calendarRefreshPending = false
    private var appliedState: CalendarSyncState?
    @Published private var reviewedPairKey: String?

    var hasConfiguredPair: Bool {
        !selectedDaouCalendar.isEmpty && !selectedGoogleCalendar.isEmpty &&
            selectedDaouCalendar != selectedGoogleCalendar
    }

    var canBeginSync: Bool {
        guard !isRunning, !enabled, calendarAccessReady, accountsConfirmed,
              hasConfiguredPair, let state = appliedState,
              state.configuration.daouCalendarURL == selectedDaouCalendar,
              state.configuration.googleCalendarID == selectedGoogleCalendar else { return false }
        return state.canBeginSystemSync(reviewedPairKey: reviewedPairKey)
    }

    init(runtimeAllowed: Bool = true, storeURL: URL = SyncStore.standardURL) {
        self.runtimeAllowed = runtimeAllowed
        do { store = try SyncStore(url: storeURL); storeInitializationError = nil }
        catch {
            store = nil
            storeInitializationError = error
            message = error.localizedDescription
        }
        observeApplicationActivation()
    }

    init(calendarAccess: any CalendarSyncAccess, store: SyncStore? = nil, runtimeAllowed: Bool = true) {
        self.runtimeAllowed = runtimeAllowed
        self.store = store
        self.storeInitializationError = nil
        self.calendarAccess = calendarAccess
        observeApplicationActivation()
    }

    private func launch(_ action: @escaping @MainActor () async -> Void) {
        guard runtimeAllowed else { return }
        let id = UUID()
        operations[id] = Task { [weak self] in
            defer { self?.operations[id] = nil }
            await action()
        }
    }
    func setRuntimeAllowed(_ allowed: Bool) {
        guard runtimeAllowed != allowed else { return }
        runtimeAllowed = allowed
        if allowed { start() } else {
            runtimeGeneration += 1; eventReadGeneration += 1
            for task in operations.values { task.cancel() }
            operations.removeAll()
            timer?.invalidate(); timer = nil
            networkMonitor?.cancel(); networkMonitor = nil
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            loaded = false; calendarRefreshPending = false
            displayedEvents = []; isLoadingEvents = false
            eventsRevision += 1
        }
    }
    func legacyConfigured() async throws -> Bool {
        if let storeInitializationError { throw storeInitializationError }
        guard let store else { return false }
        let state = try await store.load()
        return state.configuration.hasSelectedPair || state.configuration.enabled || state.lastSuccessAt != nil
    }

    private func observeApplicationActivation() {
        NotificationCenter.default.addObserver(self, selector: #selector(applicationActivated(_:)),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func applicationActivated(_ notification: Notification) {
        Task { await requestCalendarAccess(requestPermission: false) }
    }

    func start() {
        guard runtimeAllowed, !loaded else { return }
        loaded = true
        Task { await load() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runIfDue() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(woke(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        let networkMonitor = NWPathMonitor()
        self.networkMonitor = networkMonitor
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.runIfDue() }
        }
        networkMonitor.start(queue: networkQueue)
    }

    func prepareForDisplay() {
        guard runtimeAllowed else { return }
        start()
        Task { await requestCalendarAccess(requestPermission: false) }
    }

    private func invalidatePreview(_ changed: Bool) {
        guard changed else { return }
        eventReadGeneration += 1
        displayedEvents = []
        eventReadError = nil
        isLoadingEvents = false
        preview = nil
        reviewedPairKey = nil
        conflicts = []
        accountsConfirmed = false
    }

    @objc private func woke(_ notification: Notification) { runIfDue() }

    private func load() async {
        let generation = runtimeGeneration
        guard let store else { return }
        do {
            let state = try await store.load()
            guard runtimeAllowed, generation == runtimeGeneration, !Task.isCancelled else { return }
            apply(state)
            runIfDue()
        } catch { message = error.localizedDescription }
    }

    private func apply(_ state: CalendarSyncState) {
        if state.configuration.daouBaseURL == "eventkit" {
            selectedDaouCalendar = state.configuration.daouCalendarURL ?? ""
            selectedGoogleCalendar = state.configuration.googleCalendarID ?? ""
        }
        let usesSystemAccounts = state.configuration.daouBaseURL == "eventkit"
        enabled = usesSystemAccounts && state.configuration.systemAccountsConfirmed == true && state.configuration.enabled
        preview = state.hasReviewableSystemPreview ? state.lastPreview : nil
        accountsConfirmed = usesSystemAccounts && state.configuration.systemAccountsConfirmed == true
        pairLocked = state.configuration.previewAccepted || state.lastSuccessAt != nil || !state.pendingOperations.isEmpty
        var seen = Set<String>()
        conflicts = state.conflicts.values.sorted { $0.mappingID < $1.mappingID }.filter { conflict in
            let key = conflictPairKey(conflict)
            return seen.insert(key).inserted
        }
        lastSuccessAt = state.lastSuccessAt
        nextRunAt = enabled ? state.nextRunAt : nil
        lastFailureAt = state.lastFailureAt
        lastFailureCode = state.lastFailureCode
        pauseReason = state.pauseReason
        eventsRevision += 1
        appliedState = state
        if let error = state.lastErrorCode {
            message = "지난 동기화 오류: \(error)"
        } else if enabled {
            message = "자동 동기화가 켜져 있어요."
        } else if state.lastSuccessAt != nil {
            message = "자동 동기화가 일시 중지되어 있어요. 새 미리보기를 확인한 뒤 다시 시작해 주세요."
        } else {
            message = "동기화할 캘린더를 선택하고 미리보기를 먼저 확인해 주세요."
        }
    }

    private func conflictPairKey(_ conflict: SyncConflict) -> String {
        func id(_ observation: CalendarObservation) -> String {
            if case let .present(event) = observation { return event.id }
            return "deleted"
        }
        return id(conflict.daou) + "|" + id(conflict.google)
    }

    private func persistedConfiguration(_ old: CalendarSyncState) throws -> CalendarSyncState {
        guard !selectedDaouCalendar.isEmpty, !selectedGoogleCalendar.isEmpty else {
            throw SyncCoordinatorError.notConfigured
        }
        guard selectedDaouCalendar != selectedGoogleCalendar else {
            throw CalendarSyncModelError.sameCalendar
        }
        let pair = "eventkit|\(selectedDaouCalendar)|\(selectedGoogleCalendar)"
        guard accountsConfirmed else { throw CalendarSyncModelError.accountsNotConfirmed }
        if old.pairKey != pair || old.configuration.systemAccountsConfirmed != true {
            guard let daouCalendar = calendars.first(where: { $0.id == selectedDaouCalendar }),
                  let googleCalendar = calendars.first(where: { $0.id == selectedGoogleCalendar }),
                  daouCalendar.accountID != googleCalendar.accountID else {
                throw CalendarSyncModelError.accountsNotConfirmed
            }
        }
        var state = old
        state.configuration.daouBaseURL = "eventkit"
        state.configuration.daouEmail = ""
        state.configuration.googleClientID = ""
        state.configuration.daouCalendarURL = selectedDaouCalendar.isEmpty ? nil : selectedDaouCalendar
        state.configuration.googleCalendarID = selectedGoogleCalendar.isEmpty ? nil : selectedGoogleCalendar
        state.configuration.systemAccountsConfirmed = true
        if let priorPair = state.pairKey, priorPair != pair {
            if old.configuration.previewAccepted || old.lastSuccessAt != nil || !old.pendingOperations.isEmpty {
                throw CalendarSyncModelError.calendarPairLocked
            }
            state.configuration.enabled = false
            state.configuration.previewAccepted = false
            state.mappings = [:]
            state.daouObserved = [:]
            state.googleObserved = [:]
            state.googleCursor = nil
            state.pendingOperations = [:]
            state.conflicts = [:]
            state.lastPreview = nil
        }
        if state.configuration.hasSelectedPair { state.pairKey = pair }
        return state
    }

    func requestCalendarAccess(requestPermission: Bool = true) async {
        guard runtimeAllowed else { return }
        let generation = runtimeGeneration
        guard !isRunning else {
            if !requestPermission { calendarRefreshPending = true }
            return
        }
        isRunning = true
        defer { isRunning = false }
        do {
            if requestPermission { try await calendarAccess.requestAccess() }
            let values = try await calendarAccess.writableCalendars()
            guard runtimeAllowed, generation == runtimeGeneration, !Task.isCancelled else { return }
            calendars = values
            calendarAccessReady = true
            eventsRevision += 1
            message = calendars.isEmpty
                ? "쓸 수 있는 시스템 캘린더가 없습니다. 인터넷 계정에서 계정을 추가해 주세요."
                : "시스템 캘린더 \(calendars.count)개를 찾았어요."
        } catch {
            guard runtimeAllowed, generation == runtimeGeneration, !Task.isCancelled else { return }
            calendarAccessReady = false
            message = error.localizedDescription
        }
    }

    func refreshCalendars() { Task { await requestCalendarAccess() } }

    func refreshDisplayedEvents() { eventsRevision += 1 }

    /// Default adapter reads without coupling a feature view to display-loading state.
    func featureEvents(in interval: DateInterval) async throws -> [SystemCalendarDisplayEvent] {
        guard runtimeAllowed else { return [] }
        let ids = [selectedDaouCalendar, selectedGoogleCalendar].filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [] }
        return try await eventDisplayAccess.displayEvents(calendarIDs: ids, start: interval.start, end: interval.end)
    }

    func loadDisplayedEvents(start: Date, end: Date) async {
        guard runtimeAllowed else { return }
        eventReadGeneration += 1
        let generation = eventReadGeneration
        displayedEvents = []
        eventReadError = nil
        let ids = [selectedDaouCalendar, selectedGoogleCalendar].filter { !$0.isEmpty }
        guard !ids.isEmpty else { isLoadingEvents = false; return }
        isLoadingEvents = true
        defer { if generation == eventReadGeneration { isLoadingEvents = false } }
        do {
            let events = try await eventDisplayAccess.displayEvents(calendarIDs: ids, start: start, end: end)
            guard generation == eventReadGeneration, !Task.isCancelled else { return }
            displayedEvents = events
        } catch {
            guard generation == eventReadGeneration, !Task.isCancelled else { return }
            eventReadError = error.localizedDescription
        }
    }

    func openInternetAccounts() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func openCalendarPrivacy() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    private func coordinator() async throws -> SyncCoordinator {
        guard runtimeAllowed, !Task.isCancelled else { throw CancellationError() }
        guard let store else { throw SyncCoordinatorError.notConfigured }
        let state = try persistedConfiguration(try await store.load())
        try Task.checkCancellation()
        guard runtimeAllowed else { throw CancellationError() }
        try await store.save(state)
        try Task.checkCancellation()
        guard let daouID = state.configuration.daouCalendarURL,
              let googleID = state.configuration.googleCalendarID else {
            throw SyncCoordinatorError.notConfigured
        }
        return SyncCoordinator(
            store: store,
            daou: SystemCalendarProvider(side: .daou, calendarID: daouID),
            google: SystemCalendarProvider(side: .google, calendarID: googleID)
        )
    }

    func runPreview() { launch { [self] in await run(allowWrites: false) } }
    func syncNow() { launch { [self] in await run(allowWrites: true) } }

    private func run(allowWrites: Bool) async {
        guard runtimeAllowed, !Task.isCancelled, !isRunning else { return }
        if !allowWrites { reviewedPairKey = nil }
        isRunning = true
        defer { isRunning = false }
        await performRun(allowWrites: allowWrites)
    }

    private func performRun(allowWrites: Bool) async {
        let generation = runtimeGeneration
        do {
            guard runtimeAllowed, !Task.isCancelled else { return }
            let summary = try await coordinator().run(allowWrites: allowWrites)
            guard runtimeAllowed, generation == runtimeGeneration, !Task.isCancelled else { return }
            preview = summary
            let latest = try await store?.load()
            guard runtimeAllowed, generation == runtimeGeneration, !Task.isCancelled else { return }
            if let latest { apply(latest) }
            if !allowWrites { reviewedPairKey = latest?.pairKey }
            if allowWrites && latest?.lastErrorCode == "initialPendingUncertain" {
                message = "첫 일정 저장 결과가 확인되지 않아 다른 일정 반영을 보류했어요."
            } else if allowWrites && (summary.held > 0 || summary.conflicts > 0 || summary.excluded > 0) {
                message = "동기화 확인 필요 · \(summary.completed)건 반영 · \(summary.held)건 보류 · \(summary.conflicts)건 충돌 · \(summary.excluded)건 제외"
            } else {
                message = allowWrites
                    ? "동기화 완료 · \(summary.completed)건 반영"
                    : "미리보기 완료 · 시스템 캘린더는 변경하지 않았어요."
            }
        } catch {
            guard runtimeAllowed, generation == runtimeGeneration, !Task.isCancelled else { return }
            if let store, let state = try? await store.load(), runtimeAllowed, generation == runtimeGeneration { apply(state) }
            message = error.localizedDescription
        }
    }

    func beginSync() {
        launch { [self] in
            guard runtimeAllowed, !Task.isCancelled, !isRunning else { return }
            isRunning = true
            defer { isRunning = false }
            guard let store else { return }
            do {
                var state = try persistedConfiguration(try await store.load())
                try Task.checkCancellation()
                guard runtimeAllowed else { return }
                try state.beginSystemSync(reviewedPairKey: reviewedPairKey)
                try Task.checkCancellation()
                try await store.save(state)
                guard runtimeAllowed, !Task.isCancelled else { return }
                reviewedPairKey = nil
                apply(state)
                await performRun(allowWrites: true)
            } catch {
                guard runtimeAllowed, !Task.isCancelled else { return }
                message = error.localizedDescription
            }
        }
    }

    func resolveConflict(_ conflict: SyncConflict, prefer side: CalendarSide) {
        launch { [self] in
            guard runtimeAllowed, !Task.isCancelled, !isRunning, enabled else { return }
            isRunning = true
            defer { isRunning = false }
            do {
                let coordinator = try await coordinator()
                try Task.checkCancellation()
                try await coordinator.resolveConflict(mappingID: conflict.mappingID, prefer: side)
                _ = try await coordinator.run(allowWrites: false)
                try Task.checkCancellation()
                if let store {
                    let latest = try await store.load()
                    guard runtimeAllowed, !Task.isCancelled else { return }
                    apply(latest)
                }
                message = side == .daou
                    ? "다우오피스 캘린더 내용으로 충돌을 해결했어요."
                    : "Google 캘린더 내용으로 충돌을 해결했어요."
            } catch {
                guard runtimeAllowed, !Task.isCancelled else { return }
                if let store, let state = try? await store.load(), runtimeAllowed, !Task.isCancelled { apply(state) }
                message = error.localizedDescription
            }
        }
    }

    func setPaused(_ paused: Bool) {
        if !paused {
            beginSync()
            return
        }
        launch { [self] in
            guard runtimeAllowed, !Task.isCancelled, !isRunning else { return }
            isRunning = true
            defer { isRunning = false }
            guard let store else { return }
            do {
                var state = try await store.load()
                state.configuration.enabled = false
                state.nextRunAt = nil
                state.pauseReason = "userPaused"
                try Task.checkCancellation()
                try await store.save(state)
                guard runtimeAllowed, !Task.isCancelled else { return }
                reviewedPairKey = nil
                apply(state)
                message = "자동 동기화를 일시 중지했어요. 새 미리보기를 확인한 뒤 다시 시작할 수 있어요."
            } catch {
                guard runtimeAllowed, !Task.isCancelled else { return }
                message = error.localizedDescription
            }
        }
    }

    private func runIfDue() {
        guard runtimeAllowed, enabled, !isRunning, let nextRunAt, nextRunAt <= Date() else { return }
        syncNow()
    }

    func canResolveConflict(_ conflict: SyncConflict, prefer side: CalendarSide) -> Bool {
        guard enabled, !isRunning, lastSuccessAt != nil, let state = appliedState,
              let mapping = state.mappings[conflict.mappingID] else {
            return false
        }
        func eventID(_ observation: CalendarObservation) -> String? {
            if case .present(let event) = observation { return event.id }
            return nil
        }
        let daouID = eventID(conflict.daou) ?? mapping.daouEventID
        let googleID = eventID(conflict.google) ?? mapping.googleEventID
        let related = state.mappings.values.filter { item in
            item.id == mapping.id || (daouID != nil && item.daouEventID == daouID)
                || (googleID != nil && item.googleEventID == googleID)
        }
        guard !related.contains(where: {
            $0.protectedSources?.contains(side.opposite) == true || state.pendingOperations[$0.id] != nil
        }) else { return false }
        let target = side.opposite == .daou ? conflict.daou : conflict.google
        if case .present(let event) = target { return event.protectedSource != true }
        return true
    }
}
