import AppKit
import Combine
import UserNotifications
import AIUsagePlugin
import AppPluginCore
import AppPluginHost

@MainActor
public final class AIUsageModel: ObservableObject, PluginController, PluginMenuBarProviding {
    public let descriptor = PluginDescriptor(id: AIUsageModule.id, name: "AI Usage")
    @Published public private(set) var enabled = false
    @Published public private(set) var preferences: Preferences
    @Published public private(set) var snapshot: UsageSnapshot?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isLoggingIn = false
    // The host must defer automatic updates during both requests and browser sign-in.
    public var isRunning: Bool { isRefreshing || isLoggingIn }
    @Published public private(set) var message: String?
    @Published private var history: UsageHistory
    public var changes: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
    private let defaults: UserDefaults
    private let localize: PluginLocalizer
    private let notificationAuthorization: @MainActor @Sendable () async -> Bool
    private let notificationDelivery: @MainActor @Sendable (String, String, String) async throws -> Void
    private let providerFactory: @Sendable (Preferences) -> any UsageProvider
    private var active = false
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var loginAttempt: (any UsageLoginAttempt)?
    private var generation = 0
    private var failed = false
    private var alertGate: LowUsageAlertGate
    private let preferencesKey = "HappyLuluAIUsage.preferences.v1"
    private let historyKey = "HappyLuluAIUsage.history.v1"
    private let notificationKey = "HappyLuluAIUsage.notification.v1"

    public init(defaults: UserDefaults = .standard, localize: @escaping PluginLocalizer = { ko, _ in ko },
                providerFactory: @escaping @Sendable (Preferences) -> any UsageProvider = {
                    CodexUsageProvider(executablePath: $0.cliPath)
                }, notificationAuthorization: @escaping @MainActor @Sendable () async -> Bool = {
                    // Keep the non-Sendable settings object inside the system callback.
                    return await withCheckedContinuation { continuation in
                        UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
                            let status = settings.authorizationStatus
                            continuation.resume(returning: status == .authorized || status == .provisional)
                        }
                    }
                }, notificationDelivery: @escaping @MainActor @Sendable (String, String, String) async throws -> Void = { id, title, body in
                    let content = UNMutableNotificationContent(); content.title = title; content.body = body
                    try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                }) {
        self.defaults = defaults; self.localize = localize; self.providerFactory = providerFactory
        self.notificationAuthorization = notificationAuthorization; self.notificationDelivery = notificationDelivery
        var saved = defaults.data(forKey: "HappyLuluAIUsage.preferences.v1")
            .flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        saved.normalize(); preferences = saved
        history = defaults.data(forKey: "HappyLuluAIUsage.history.v1")
            .flatMap { try? JSONDecoder().decode(UsageHistory.self, from: $0) } ?? UsageHistory()
        alertGate = LowUsageAlertGate(deliveredKey: defaults.string(forKey: "HappyLuluAIUsage.notification.v1"))
    }

    public func text(_ korean: String, _ english: String) -> String { localize(korean, english) }
    public var connectionState: PluginConnectionState {
        if !enabled { return .off }
        if isRunning { return .connecting }
        if failed { return .attention }
        return snapshot == nil ? .setup : .ready
    }
    public var isStale: Bool { failed || snapshot?.isStale(intervalMinutes: preferences.refreshMinutes) == true }
    public var analysis: UsageAnalysis { snapshot == nil ? UsageHistory().analysis() : history.analysis() }
    public var menuBarItem: PluginMenuBarItem? {
        guard active, enabled else { return nil }
        let name = providerFactory(preferences).name
        let value = snapshot.map { "\($0.weekly.remainingPercent)%" } ?? "—"
        let title = (preferences.labelFormat == .named ? name + " " : "") + value + (isStale && snapshot != nil ? " ·" : "")
        return PluginMenuBarItem(id: descriptor.id, title: title,
            accessibilityLabel: name + " " + text("주간 잔여량", "weekly remaining") + " " + value +
                (isStale ? text(" · 이전 조회 값", " · previous reading") : ""))
    }
    public func setEnabled(_ value: Bool) {
        enabled = value
        if !value { stop() }
    }
    public func start() {
        guard enabled, !active else { return }
        active = true
        schedule()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshData() } }
        refreshData()
    }
    public func stop() {
        active = false; generation += 1
        timer?.invalidate(); timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        task?.cancel(); task = nil
        loginAttempt?.cancel(); loginAttempt = nil
        loginTask?.cancel(); loginTask = nil
        isRefreshing = false; isLoggingIn = false; snapshot = nil; failed = false; message = nil
    }
    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(preferences.refreshMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshData() }
        }
    }
    public func refreshData() {
        guard enabled, active, !isRunning else { return }
        isRefreshing = true
        generation += 1
        let current = generation
        let provider = providerFactory(preferences)
        task = Task { [weak self] in
            do {
                let value = try await provider.fetch()
                guard let self, !Task.isCancelled, self.generation == current, self.active, self.enabled else { return }
                if self.defaults.string(forKey: "HappyLuluAIUsage.notificationAccount.v1") != value.accountKey {
                    self.alertGate = LowUsageAlertGate()
                    self.defaults.removeObject(forKey: self.notificationKey)
                    self.defaults.set(value.accountKey, forKey: "HappyLuluAIUsage.notificationAccount.v1")
                }
                self.snapshot = value
                self.history.record(value, cadenceMinutes: self.preferences.refreshMinutes)
                if self.history.canPersist, let data = try? JSONEncoder().encode(self.history) {
                    self.defaults.set(data, forKey: self.historyKey)
                } else { self.defaults.removeObject(forKey: self.historyKey) }
                self.failed = false; self.message = nil
                await self.notifyIfNeeded(value.weekly, generation: current)
            } catch {
                guard let self, !Task.isCancelled, self.generation == current, self.active else { return }
                self.failed = true
                self.message = self.errorMessage(error)
                if let error = error as? UsageError {
                    switch error {
                    case .notLoggedIn, .unsupportedAccount, .noWeeklyQuota, .noCodexQuota:
                        self.snapshot = nil; self.clearHistory()
                    default: break
                    }
                }
            }
            guard let self, self.generation == current else { return }
            self.isRefreshing = false; self.task = nil
        }
    }
    private func clearHistory() {
        history.clear(); defaults.removeObject(forKey: historyKey)
    }
    public func updatePreferences(_ change: (inout Preferences) -> Void) {
        var next = preferences; change(&next); next.normalize()
        guard next != preferences, let data = try? JSONEncoder().encode(next) else { return }
        let pathChanged = next.cliPath != preferences.cliPath
        preferences = next; defaults.set(data, forKey: preferencesKey)
        if pathChanged {
            let wasActive = active
            stop(); clearHistory()
            if wasActive { start() }
        } else if active { schedule() }
    }
    public func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = text("Codex 실행 파일 선택", "Choose Codex executable")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try CodexExecutable.resolve(customPath: url.path)
            updatePreferences { $0.cliPath = url.path }
        } catch { message = errorMessage(error) }
    }
    public var executablePath: String { (try? CodexExecutable.resolve(customPath: preferences.cliPath).path) ?? "—" }
    public func login() {
        guard active, enabled, !isRunning,
              let attempt = providerFactory(preferences).makeLoginAttempt() else { return }
        generation += 1
        let current = generation
        loginAttempt = attempt; isLoggingIn = true
        message = text("브라우저에서 인증을 완료해 주세요.", "Complete sign-in in your browser.")
        loginTask = Task { [weak self] in
            do {
                try await attempt.login { [weak self] url in
                    Task { @MainActor in
                        guard let self, self.active, self.generation == current else { return }
                        if !NSWorkspace.shared.open(url) { self.cancelLogin() }
                    }
                }
                guard let self, !Task.isCancelled, self.active, self.generation == current else { return }
                self.loginAttempt = nil; self.loginTask = nil; self.isLoggingIn = false
                self.snapshot = nil; self.clearHistory(); self.message = nil
                self.alertGate = LowUsageAlertGate(); self.defaults.removeObject(forKey: self.notificationKey)
                self.refreshData()
            } catch {
                guard let self, !Task.isCancelled, self.generation == current else { return }
                self.loginAttempt = nil; self.loginTask = nil; self.isLoggingIn = false
                self.message = self.errorMessage(error)
            }
        }
    }
    public func cancelLogin() {
        generation += 1
        loginAttempt?.cancel(); loginAttempt = nil
        loginTask?.cancel(); loginTask = nil
        isLoggingIn = false; message = nil
    }
    private func notifyIfNeeded(_ window: UsageWindow, generation current: Int) async {
        let threshold = preferences.notificationThreshold
        guard let key = alertGate.pendingKey(for: window, threshold: threshold,
            enabled: preferences.notificationsEnabled) else { return }
        let authorized = await notificationAuthorization()
        guard active, enabled, generation == current, preferences.notificationsEnabled, authorized,
              preferences.notificationThreshold == threshold else { return }
        let title = text("Codex 주간 잔여량 \(window.remainingPercent)%", "Codex weekly remaining \(window.remainingPercent)%")
        let body = text("설정한 \(threshold)% 이하입니다.", "At or below your \(threshold)% threshold.")
        do {
            try await notificationDelivery("ai-usage-" + key, title, body)
            guard active, generation == current else { return }
            alertGate.markDelivered(key); defaults.set(key, forKey: notificationKey)
        } catch {
            guard active, generation == current else { return }
            message = text("알림을 보내지 못했습니다. 시스템 알림 설정을 확인해 주세요.", "Could not send a notification. Check System Settings.")
        }
    }
    public func setNotifications(_ enabled: Bool) {
        updatePreferences { $0.notificationsEnabled = enabled }
        guard enabled else { return }
        Task { [weak self] in
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
            guard let self, self.enabled, self.preferences.notificationsEnabled else { return }
            if !granted {
                self.updatePreferences { $0.notificationsEnabled = false }
                self.message = self.text("시스템 설정에서 HappyLulu 알림을 허용해 주세요.", "Allow HappyLulu notifications in System Settings.")
            }
        }
    }
    private func errorMessage(_ error: Error) -> String {
        if localize("ko", "en") == "ko" { return error.localizedDescription }
        switch error as? UsageError {
        case .notLoggedIn: return "Sign in with ChatGPT to view weekly usage."
        case .unsupportedAccount: return "API key accounts do not provide a ChatGPT weekly allowance."
        case .cliNotFound: return "Codex was not found. Choose the executable in connection settings."
        case .noWeeklyQuota: return "This account did not provide a weekly allowance."
        case .timeout, .loginTimeout: return "The request timed out. Try again."
        default: return "Could not read Codex usage. Check your connection and sign-in, then refresh."
        }
    }
}
