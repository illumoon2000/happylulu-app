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
    private let eventDisplayAccess = SystemCalendarAccess()

    private let calendarAccess: any CalendarSyncAccess
    private let store: SyncStore?
    private var timer: Timer?
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "HappyLulu.CalendarNetwork")
    private var loaded = false
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

    init() {
        calendarAccess = SystemCalendarAccess()
        do { store = try SyncStore() }
        catch {
            store = nil
            message = error.localizedDescription
        }
        observeApplicationActivation()
    }

    init(calendarAccess: any CalendarSyncAccess, store: SyncStore? = nil) {
        self.calendarAccess = calendarAccess
        self.store = store
        observeApplicationActivation()
    }

    private func observeApplicationActivation() {
        NotificationCenter.default.addObserver(self, selector: #selector(applicationActivated(_:)),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func applicationActivated(_ notification: Notification) {
        Task { await requestCalendarAccess(requestPermission: false) }
    }

    func start() {
        guard !loaded else { return }
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
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.runIfDue() }
        }
        networkMonitor.start(queue: networkQueue)
    }

    func prepareForDisplay() {
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
        guard let store else { return }
        do {
            let state = try await store.load()
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
        guard !isRunning else {
            if !requestPermission { calendarRefreshPending = true }
            return
        }
        isRunning = true
        defer { isRunning = false }
        do {
            if requestPermission { try await calendarAccess.requestAccess() }
            calendars = try await calendarAccess.writableCalendars()
            calendarAccessReady = true
            eventsRevision += 1
            message = calendars.isEmpty
                ? "쓸 수 있는 시스템 캘린더가 없습니다. 인터넷 계정에서 계정을 추가해 주세요."
                : "시스템 캘린더 \(calendars.count)개를 찾았어요."
        } catch {
            calendarAccessReady = false
            message = error.localizedDescription
        }
    }

    func refreshCalendars() { Task { await requestCalendarAccess() } }

    func refreshDisplayedEvents() { eventsRevision += 1 }

    func loadDisplayedEvents(start: Date, end: Date) async {
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
        guard let store else { throw SyncCoordinatorError.notConfigured }
        let state = try persistedConfiguration(try await store.load())
        try await store.save(state)
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

    func runPreview() { Task { await run(allowWrites: false) } }
    func syncNow() { Task { await run(allowWrites: true) } }

    private func run(allowWrites: Bool) async {
        guard !isRunning else { return }
        if !allowWrites { reviewedPairKey = nil }
        isRunning = true
        defer { isRunning = false }
        await performRun(allowWrites: allowWrites)
    }

    private func performRun(allowWrites: Bool) async {
        do {
            let summary = try await coordinator().run(allowWrites: allowWrites)
            preview = summary
            let latest = try await store?.load()
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
            if let store, let state = try? await store.load() { apply(state) }
            message = error.localizedDescription
        }
    }

    func beginSync() {
        Task {
            guard !isRunning else { return }
            isRunning = true
            defer { isRunning = false }
            guard let store else { return }
            do {
                var state = try persistedConfiguration(try await store.load())
                try state.beginSystemSync(reviewedPairKey: reviewedPairKey)
                try await store.save(state)
                reviewedPairKey = nil
                apply(state)
                await performRun(allowWrites: true)
            } catch { message = error.localizedDescription }
        }
    }

    func resolveConflict(_ conflict: SyncConflict, prefer side: CalendarSide) {
        Task {
            guard !isRunning, enabled else { return }
            isRunning = true
            defer { isRunning = false }
            do {
                let coordinator = try await coordinator()
                try await coordinator.resolveConflict(mappingID: conflict.mappingID, prefer: side)
                _ = try await coordinator.run(allowWrites: false)
                if let store { apply(try await store.load()) }
                message = side == .daou
                    ? "다우오피스 캘린더 내용으로 충돌을 해결했어요."
                    : "Google 캘린더 내용으로 충돌을 해결했어요."
            } catch {
                if let store, let state = try? await store.load() { apply(state) }
                message = error.localizedDescription
            }
        }
    }

    func setPaused(_ paused: Bool) {
        if !paused {
            beginSync()
            return
        }
        Task {
            guard !isRunning else { return }
            isRunning = true
            defer { isRunning = false }
            guard let store else { return }
            do {
                var state = try await store.load()
                state.configuration.enabled = false
                state.nextRunAt = nil
                state.pauseReason = "userPaused"
                try await store.save(state)
                reviewedPairKey = nil
                apply(state)
                message = "자동 동기화를 일시 중지했어요. 새 미리보기를 확인한 뒤 다시 시작할 수 있어요."
            } catch { message = error.localizedDescription }
        }
    }

    private func runIfDue() {
        guard enabled, !isRunning, let nextRunAt, nextRunAt <= Date() else { return }
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
