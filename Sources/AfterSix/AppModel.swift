import AppKit
import Combine
import ServiceManagement
import AfterSixCore
import AppPluginCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: AttendanceState
    @Published private(set) var now = Date()
    @Published var errorMessage: String?
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var calendarHalfDayMode: WorkdayMode?
    @Published private(set) var calendarHalfDayMessage: String?
    @Published private(set) var countdownDisplay = CountdownDisplay.saved()
    let store: StateStore
    private var writable = true
    private var timer: Timer?
    private var lastPeriodicRefreshAt: Date?
    private let attendance: any AttendanceAdapter
    private let featureRouter: FeatureAdapterRouter
    private var featureObservation: AnyCancellable?
    private var observedHalfDaySource: String
    private var observedHalfDaySnapshotAt: Date?
    private var halfDayRefreshGeneration = 0
    private var calendarModeDay: String?
    private var lastCalendarCheckAt: Date?
    private var pendingArrivals: [(at: Date, isLogin: Bool)] = []
    private var processingArrivals = false
    private var calendarDetectionRequestGeneration = 0

    var isProcessingAttendance: Bool { processingArrivals }

    var calendar: Calendar { Calendar.current }
    var arrival: Arrival? { attendance.today(in: state, now: now, calendar: calendar) }
    var departure: Date? { arrival.map { attendance.departure(for: $0, settings: state.settings) } }
    var isSkipped: Bool { state.suppressedDays.contains(attendance.dayKey(now, calendar: calendar)) }
    var minutesLeft: Int? { departure.map { attendance.remainingMinutes(until: $0, now: now) } }
    var countdownText: String {
        countdownDisplay.text(seconds: departure?.timeIntervalSince(now) ?? 0, korean: L("ko", "en") == "ko")
    }
    func setCountdownDisplay(_ choice: CountdownDisplay) {
        choice.save()
        countdownDisplay = choice
        now = Date()
        if timer != nil { startCountdownTimer() }
    }
    private var countdownRefreshInterval: TimeInterval {
        (departure.map { $0 > now } ?? false) ? countdownDisplay.refreshInterval : 1
    }
    private func startCountdownTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: countdownRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    var postDepartureStatus: PostDepartureStatus? {
        attendance.postDepartureStatus(in: state, now: now, calendar: calendar)
    }
    var earlyLeaveMinutes: Int {
        if let arrival { return arrival.mode == .normal ? attendance.earlyLeaveMinutes(for: arrival) : 0 }
        return attendance.earlyLeaveMinutes(on: now, timeZone: calendar.timeZone)
    }
    var detectedModeToday: WorkdayMode? {
        calendarModeDay == attendance.dayKey(now, calendar: calendar) ? calendarHalfDayMode : nil
    }
    var progress: Double {
        guard let arrival, let departure else { return 0 }
        return attendance.progress(from: arrival.time, until: departure, now: now)
    }
    var menuTitle: String {
        guard let minutesLeft else { return isSkipped ? L("오늘 쉬는 날", "Day off today") : L("출근 대기", "Waiting for arrival") }
        guard minutesLeft == 0 else { return L("퇴근 \(countdownText)", "Leave in \(countdownText)") }
        if let extraMinutes = postDepartureStatus?.extraMinutes { return extraLabel(extraMinutes) }
        return L("퇴근 가능", "Ready to leave")
    }
    func extraLabel(_ minutes: Int) -> String {
        L("추가 \(minutes)분 중", "Extra \(minutes) min")
    }
    func mealStatusLabel(_ status: PostDepartureStatus) -> String {
        guard let departure else { return L("식대 기준", "Meal threshold") }
        let thresholdTime = timeLabel(departure.addingTimeInterval(TimeInterval(Attendance.mealReferenceThresholdMinutes * 60)))
        return status.mealThresholdReached
            ? L("식대 기준 \(thresholdTime) 도달", "Meal threshold \(thresholdTime) reached")
            : L("식대 기준 \(thresholdTime) · \(status.mealMinutesRemaining)분 남음",
                "Meal threshold \(thresholdTime) · \(status.mealMinutesRemaining) min left")
    }
    var loginEnabled: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }
    var loginDescription: String {
        switch loginStatus {
        case .enabled: L("로그인 시 자동 실행 켜짐", "Launch at login is on")
        case .requiresApproval: L("시스템 설정에서 허용이 필요합니다", "Allow in System Settings")
        case .notRegistered: L("로그인 시 자동 실행 꺼짐", "Launch at login is off")
        case .notFound: L("앱을 응용 프로그램 폴더에서 실행해 주세요", "Run the app from Applications")
        @unknown default: L("자동 실행 상태 확인 필요", "Check launch-at-login status")
        }
    }

    init(store: StateStore = .standard, attendance: any AttendanceAdapter = DefaultAttendanceAdapter(),
         featureRouter: FeatureAdapterRouter) {
        self.store = store; self.attendance = attendance; self.featureRouter = featureRouter
        observedHalfDaySource = featureRouter.selectedID(for: .halfDay)
        do { state = try store.load() }
        catch {
            state = AttendanceState()
            writable = false
            errorMessage = "저장된 기록을 불러오지 못했습니다. 원본을 보존했으며 새 기록 저장을 중지했습니다. \(error.localizedDescription)"
        }
    }

    func observeFeatures(_ manager: PluginManagerModel) {
        featureObservation = manager.$revision.sink { [weak self, weak manager] _ in
            Task { @MainActor [weak self, weak manager] in
                guard let self, let manager else { return }
                let source = self.featureRouter.selectedID(for: .halfDay)
                let fetchedAt = manager.registry.snapshot(for: source)?.fetchedAt
                guard source != self.observedHalfDaySource || fetchedAt != self.observedHalfDaySnapshotAt else { return }
                // Account/session replacement clears a plugin's snapshot without changing its source ID.
                // A temporary fetch failure keeps that snapshot, so it still preserves the last good mode.
                let snapshotCleared = self.observedHalfDaySnapshotAt != nil && fetchedAt == nil
                if source != self.observedHalfDaySource || snapshotCleared {
                    self.observedHalfDaySource = source
                    self.calendarDetectionRequestGeneration += 1
                    self.calendarHalfDayMode = nil; self.calendarModeDay = nil
                    self.calendarHalfDayMessage = nil; self.lastCalendarCheckAt = nil
                    if self.state.detectHalfDaysFromCalendar { self.applyCalendarHalfDay(nil, checkedAt: Date()) }
                }
                self.observedHalfDaySnapshotAt = fetchedAt
                if self.state.detectHalfDaysFromCalendar { await self.refreshCalendarHalfDay(force: true) }
            }
        }
    }

    var arrivalHistory: [String: [Arrival]] { attendance.history(in: state) }
    func dayKey(_ day: Date, calendar: Calendar? = nil) -> String {
        attendance.dayKey(day, calendar: calendar ?? self.calendar)
    }
    func isSuppressed(_ day: Date, calendar: Calendar) -> Bool {
        state.suppressedDays.contains(dayKey(day, calendar: calendar)) || state.suppressedDays.contains(dayKey(day))
    }
    func saveManualClock(_ clock: Date, forDay day: String, selectedMode: WorkdayMode?) -> Bool {
        refresh()
        guard day == dayKey(now) else {
            errorMessage = "날짜가 바뀌었습니다. 입력 창을 다시 열어 주세요."
            return false
        }
        let components = calendar.dateComponents([.hour, .minute], from: clock)
        guard let hour = components.hour, let minute = components.minute,
              let date = calendar.date(bySettingHour: hour, minute: minute, second: 0,
                                       of: calendar.startOfDay(for: now)) else { return false }
        return saveManual(date, selectedMode: selectedMode)
    }

    func start(loginObservedAt: Date? = nil) {
        // This notification is used by macOS but is not a documented Apple API.
        // A wake/session-active notification must never be treated as an unlock.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenUnlocked(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
            suspensionBehavior: .drop
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(woke(_:)), name: NSWorkspace.didWakeNotification, object: nil
        )
        if let loginObservedAt { enqueueArrival(at: loginObservedAt, isLogin: true) }
        startCountdownTimer()
        if state.detectHalfDaysFromCalendar { Task { await refreshCalendarHalfDay(force: true) } }
        // Register once; never fight a user's later System Settings choice.
        if writable, !state.didOfferLoginItem {
            setLoginEnabled(true)
        }
    }

    func refresh() {
        now = Date()
        lastPeriodicRefreshAt = now
        loginStatus = SMAppService.mainApp.status
        if state.detectHalfDaysFromCalendar,
           lastCalendarCheckAt.map({ now.timeIntervalSince($0) >= 300 }) ?? true {
            Task { await refreshCalendarHalfDay() }
        }
    }

    private func tick() {
        now = Date()
        if timer?.timeInterval != countdownRefreshInterval { startCountdownTimer() }
        if lastPeriodicRefreshAt.map({ now.timeIntervalSince($0) >= 15 }) ?? true {
            refresh()
        }
    }

    @objc private func woke(_ notification: Notification) { refresh() }

    @objc private func screenUnlocked(_ notification: Notification) {
        enqueueArrival(at: Date(), isLogin: false)
    }

    private func enqueueArrival(at receivedAt: Date, isLogin: Bool) {
        now = receivedAt
        pendingArrivals.append((receivedAt, isLogin))
        guard !processingArrivals else { return }
        processingArrivals = true
        Task { await processPendingArrivals() }
    }

    private func processPendingArrivals() async {
        while !pendingArrivals.isEmpty {
            let event = pendingArrivals.removeFirst()
            let receivedAt = event.at
            var observation = CalendarModeObservation.confirmed(nil)
            if state.detectHalfDaysFromCalendar {
                do {
                    observation = .confirmed(HalfDayRecognition.mode(from: try await featureRouter.halfDayTitles(on: receivedAt, timeZone: calendar.timeZone)))
                } catch {
                    observation = .unavailable
                    calendarHalfDayMessage = error.localizedDescription
                }
            }
            // A setting change while EventKit was pending takes effect before
            // this arrival is saved; FIFO keeps the first observed login/unlock first.
            let detected = state.detectHalfDaysFromCalendar
                ? observation.resolved(previous: detectedModeToday) : nil
            commit { state in
                if event.isLogin {
                    _ = try attendance.apply(.login(at: receivedAt, mode: detected), to: &state, calendar: calendar)
                } else {
                    _ = try attendance.apply(.unlock(at: receivedAt, mode: detected), to: &state, calendar: calendar)
                }
            }
            if state.detectHalfDaysFromCalendar, case let .confirmed(mode) = observation {
                lastCalendarCheckAt = receivedAt
                applyCalendarHalfDay(mode, checkedAt: receivedAt)
            }
        }
        processingArrivals = false
    }

    @discardableResult
    private func commit(_ change: (inout AttendanceState) throws -> Void) -> Bool {
        guard writable else { return false }
        do {
            var updated = state
            try change(&updated)
            try store.save(updated)
            state = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = "저장하지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func saveManual(_ date: Date, selectedMode: WorkdayMode?) -> Bool {
        refresh()
        return commit {
            _ = try attendance.apply(.manual(at: date, now: now, selectedMode: selectedMode, calendarMode: detectedModeToday), to: &$0, calendar: calendar)
        }
    }

    func setCalendarHalfDayDetection(_ enabled: Bool) {
        calendarDetectionRequestGeneration += 1
        let requestGeneration = calendarDetectionRequestGeneration
        if !enabled {
            guard commit({ $0.detectHalfDaysFromCalendar = false }) else { return }
            calendarHalfDayMode = nil
            calendarModeDay = nil
            calendarHalfDayMessage = nil
            var updated = state
            if (try? attendance.apply(.refreshMode(now: now, mode: nil), to: &updated, calendar: calendar)) == true {
                commit { $0 = updated }
            }
            return
        }
        Task {
            do {
                try await featureRouter.requestHalfDayAccess()
                guard requestGeneration == calendarDetectionRequestGeneration else { return }
                guard commit({ $0.detectHalfDaysFromCalendar = true }) else { return }
                await refreshCalendarHalfDay(force: true)
            } catch {
                if requestGeneration == calendarDetectionRequestGeneration {
                    calendarHalfDayMessage = error.localizedDescription
                }
            }
        }
    }

    func checkCalendarHalfDayNow() { Task { await refreshCalendarHalfDay(force: true) } }

    private func refreshCalendarHalfDay(force: Bool = false) async {
        guard state.detectHalfDaysFromCalendar else { return }
        let checkedAt = Date()
        if !force, let lastCalendarCheckAt, checkedAt.timeIntervalSince(lastCalendarCheckAt) < 300 { return }
        lastCalendarCheckAt = checkedAt
        halfDayRefreshGeneration += 1
        let request = halfDayRefreshGeneration
        let detection = calendarDetectionRequestGeneration
        do {
            let mode = HalfDayRecognition.mode(from: try await featureRouter.halfDayTitles(on: checkedAt, timeZone: calendar.timeZone))
            guard state.detectHalfDaysFromCalendar, request == halfDayRefreshGeneration,
                  detection == calendarDetectionRequestGeneration else { return }
            applyCalendarHalfDay(mode, checkedAt: checkedAt)
        } catch is CancellationError {
        } catch {
            // A failed read is not evidence that the calendar event disappeared.
            // Keep the last successful result until a confirmed fresh read.
            if request == halfDayRefreshGeneration, detection == calendarDetectionRequestGeneration {
                calendarHalfDayMessage = error.localizedDescription
            }
        }
    }

    private func applyCalendarHalfDay(_ mode: WorkdayMode?, checkedAt: Date) {
        let day = attendance.dayKey(checkedAt, calendar: calendar)
        guard day == attendance.dayKey(Date(), calendar: calendar) else { return }
        calendarModeDay = day
        calendarHalfDayMode = mode
        let conflictsWithRecordedTime = mode.flatMap { selected in
            state.arrivals[day].map { arrival in
                arrival.modeSource == .automatic &&
                    !attendance.isAllowed(arrival.time, for: selected, calendar: calendar)
            }
        } ?? false
        if conflictsWithRecordedTime {
            calendarHalfDayMessage = "캘린더 반차와 기록된 출근 시각이 맞지 않아 출근 시각으로 다시 판단했어요. 필요하면 근무 유형을 직접 지정해 주세요."
        } else {
            calendarHalfDayMessage = mode.map { "캘린더에서 \($0.label)를 인식했어요." }
                ?? "명확한 오전·오후 반차 일정이 없어요. 출근 시각으로 판단합니다."
        }
        var updated = state
        if (try? attendance.apply(.refreshMode(now: checkedAt, mode: mode), to: &updated, calendar: calendar)) == true {
            commit { $0 = updated }
        }
    }

    func skipToday() {
        refresh()
        commit { _ = try attendance.apply(.skip(now: now), to: &$0, calendar: calendar) }
    }

    func updateSettings(work: Int, rest: Int) {
        commit {
            _ = try attendance.apply(.settings(work: work, rest: rest), to: &$0, calendar: calendar)
        }
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled && SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                try SMAppService.mainApp.register()
            } else if !enabled && SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch { errorMessage = "자동 실행 설정: \(error.localizedDescription)" }
        loginStatus = SMAppService.mainApp.status
        let applied = enabled ? (loginStatus == .enabled || loginStatus == .requiresApproval) : loginStatus == .notRegistered
        if applied && !state.didOfferLoginItem {
            commit { $0.didOfferLoginItem = true }
        }
    }

    func duration(_ minutes: Int) -> String {
        let seconds = TimeInterval(minutes) * 60
        return L(CountdownDisplay.hoursMinutes.text(seconds: seconds, korean: true),
                 CountdownDisplay.hoursMinutes.text(seconds: seconds, korean: false))
    }

    func timeLabel(_ date: Date) -> String {
        displayClock(date, timeZone: calendar.timeZone)
    }

    func showData() { NSWorkspace.shared.selectFile(store.url.path, inFileViewerRootedAtPath: "") }
}
