import AppKit
import Combine
import ServiceManagement
import AfterSixCore

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
    private let halfDayCalendar = HalfDayCalendarReader()
    private var calendarModeDay: String?
    private var lastCalendarCheckAt: Date?
    private var pendingArrivals: [(at: Date, isLogin: Bool)] = []
    private var processingArrivals = false
    private var calendarDetectionRequestGeneration = 0

    var isProcessingAttendance: Bool { processingArrivals }

    var calendar: Calendar { Calendar.current }
    var arrival: Arrival? { Attendance.today(in: state, now: now, calendar: calendar) }
    var departure: Date? { arrival.map { Attendance.departure(for: $0, settings: state.settings) } }
    var isSkipped: Bool { state.suppressedDays.contains(Attendance.dayKey(now, calendar: calendar)) }
    var minutesLeft: Int? { departure.map { Attendance.remainingMinutes(until: $0, now: now) } }
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
        Attendance.postDepartureStatus(in: state, now: now, calendar: calendar)
    }
    var earlyLeaveMinutes: Int {
        if let arrival { return arrival.mode == .normal ? Attendance.earlyLeaveMinutes(for: arrival) : 0 }
        return Attendance.earlyLeaveMinutes(on: now, timeZone: calendar.timeZone)
    }
    var detectedModeToday: WorkdayMode? {
        calendarModeDay == Attendance.dayKey(now, calendar: calendar) ? calendarHalfDayMode : nil
    }
    var progress: Double {
        guard let arrival, let departure else { return 0 }
        return Attendance.progress(from: arrival.time, until: departure, now: now)
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

    init(store: StateStore = .standard) {
        self.store = store
        do { state = try store.load() }
        catch {
            state = AttendanceState()
            writable = false
            errorMessage = "저장된 기록을 불러오지 못했습니다. 원본을 보존했으며 새 기록 저장을 중지했습니다. \(error.localizedDescription)"
        }
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
                    observation = .confirmed(try await halfDayCalendar.detect(on: receivedAt,
                                                                              timeZone: calendar.timeZone))
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
                    Attendance.recordLogin(in: &state, at: receivedAt, calendar: calendar,
                                           calendarMode: detected)
                } else {
                    Attendance.recordUnlock(in: &state, at: receivedAt, calendar: calendar,
                                            calendarMode: detected)
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
            try Attendance.setManual(in: &$0, at: date, now: now, calendar: calendar,
                                     selectedMode: selectedMode, calendarMode: detectedModeToday)
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
            if Attendance.refreshAutomaticMode(in: &updated, now: now, calendar: calendar,
                                                calendarMode: nil) {
                commit { $0 = updated }
            }
            return
        }
        Task {
            do {
                try await halfDayCalendar.requestAccess()
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
        do {
            let mode = try await halfDayCalendar.detect(on: checkedAt, timeZone: calendar.timeZone)
            guard state.detectHalfDaysFromCalendar else { return }
            applyCalendarHalfDay(mode, checkedAt: checkedAt)
        } catch {
            // A failed read is not evidence that the calendar event disappeared.
            // Keep the last successful result until a confirmed fresh read.
            calendarHalfDayMessage = error.localizedDescription
        }
    }

    private func applyCalendarHalfDay(_ mode: WorkdayMode?, checkedAt: Date) {
        let day = Attendance.dayKey(checkedAt, calendar: calendar)
        guard day == Attendance.dayKey(Date(), calendar: calendar) else { return }
        calendarModeDay = day
        calendarHalfDayMode = mode
        let conflictsWithRecordedTime = mode.flatMap { selected in
            state.arrivals[day].map { arrival in
                arrival.modeSource == .automatic &&
                    !Attendance.isAllowed(arrival.time, for: selected, calendar: calendar)
            }
        } ?? false
        if conflictsWithRecordedTime {
            calendarHalfDayMessage = "캘린더 반차와 기록된 출근 시각이 맞지 않아 출근 시각으로 다시 판단했어요. 필요하면 근무 유형을 직접 지정해 주세요."
        } else {
            calendarHalfDayMessage = mode.map { "캘린더에서 \($0.label)를 인식했어요." }
                ?? "명확한 오전·오후 반차 일정이 없어요. 출근 시각으로 판단합니다."
        }
        var updated = state
        if Attendance.refreshAutomaticMode(in: &updated, now: checkedAt,
                                            calendar: calendar, calendarMode: mode) {
            commit { $0 = updated }
        }
    }

    func skipToday() {
        refresh()
        commit { Attendance.skipToday(in: &$0, now: now, calendar: calendar) }
    }

    func updateSettings(work: Int, rest: Int) {
        commit {
            $0.settings.workMinutes = work
            $0.settings.breakMinutes = rest
            guard $0.settings.isValid else { throw AttendanceError.invalidSettings }
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
