import Foundation
import Combine
import AppPluginCore
import DaouOfficePlugin
import AppPluginHost

@MainActor
final class DaouOfficePluginModel: ObservableObject {
    @Published var address = "" { didSet { if address != oldValue { draftChanged() } } }
    @Published var loginID = "" { didSet { if loginID != oldValue { draftChanged() } } }
    @Published var password = "" { didSet { if password != oldValue { draftChanged() } } }
    @Published var captchaAnswer = ""
    @Published private(set) var captchaChallenge: DaouOfficeCaptchaChallenge?
    @Published private(set) var captchaRequired = false
    @Published private(set) var enableRequested = false
    @Published private(set) var enabled = false
    @Published private(set) var isRunning = false
    @Published private(set) var snapshot: PluginSnapshot?
    @Published private(set) var failure: PluginFailure?
    @Published private(set) var nextRunAt: Date?
    @Published private(set) var hasSavedPassword = false
    @Published private(set) var diagnostic: DaouOfficeAPIDiagnostic?
    @Published private(set) var lastLoginDiagnostic: DaouOfficeAPIDiagnostic?
    @Published private(set) var captchaLoginRejected = false
    private let registry: PluginRegistry
    private let plugin = DaouOfficeAppPlugin()
    private let store: DaouOfficeConfigurationStore
    private let secrets: any PluginSecretStore
    private let makeClient: @Sendable (DaouOfficeConfiguration, any PluginSecretStore) -> DaouOfficeAPIClient
    private var configuration: DaouOfficeConfiguration?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var failures = 0
    private var started = false
    private var registered = false
    private let localize: PluginLocalizer

    /// Other app features consume the same immutable plugin API as the settings screen.
    var api: any PluginDataProviding { registry }
    var canUseSavedPassword: Bool {
        guard hasSavedPassword, let configuration,
              let draft = try? DaouOfficeConfiguration(enabled: true, address: address, loginID: loginID) else { return false }
        return draft.credentialKey == configuration.credentialKey
    }
    var canSave: Bool {
        registered && enableRequested && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !loginID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (!password.isEmpty || canUseSavedPassword) && !isRunning && !captchaRequired
    }
    private var matchesSavedConnection: Bool {
        guard let configuration,
              let draft = try? DaouOfficeConfiguration(enabled: true, address: address, loginID: loginID) else { return false }
        return draft.credentialKey == configuration.credentialKey && password.isEmpty
    }
    var canRefresh: Bool { enabled && !isRunning && captchaChallenge == nil && matchesSavedConnection }
    var canSubmitCaptcha: Bool {
        enabled && !isRunning && captchaChallenge != nil && matchesSavedConnection &&
            !captchaAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canReloadCaptcha: Bool { enabled && !isRunning && captchaChallenge != nil && matchesSavedConnection }

    private enum Operation {
        case refresh
        case submitCaptcha(String, UUID)
        case reloadCaptcha(UUID)
    }
    init(store: DaouOfficeConfigurationStore = DaouOfficeConfigurationStore(),
         secrets: any PluginSecretStore = DaouOfficeSecretStore(),
         registry: PluginRegistry = PluginRegistry(),
         localize: @escaping PluginLocalizer = { korean, _ in korean },
         makeClient: @escaping @Sendable (DaouOfficeConfiguration, any PluginSecretStore) -> DaouOfficeAPIClient = {
             DaouOfficeAPIClient(configuration: $0, secrets: $1, transport: DaouOfficeCurlTransport(), log: .standard)
         }) {
        self.localize = localize
        self.store = store; self.secrets = secrets; self.registry = registry; self.makeClient = makeClient
        do { try registry.register(plugin); registered = true }
        catch { failure = .duplicatePlugin; return }
        do {
            if let config = try store.load() {
                configuration = config; address = config.baseURL.absoluteString; loginID = config.loginID
                enabled = config.enabled; enableRequested = config.enabled
                do { hasSavedPassword = try secrets.load(for: config.credentialKey)?.isEmpty == false }
                catch { failure = .credentials }
            }
        } catch { failure = .configuration }
    }

    func start() {
        guard registered, !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let next = self.nextRunAt, next <= Date(), self.enabled else { return }
                self.refresh()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        if enabled, let config = configuration { connect(config); refresh() }
    }

    func setEnableRequested(_ value: Bool) {
        guard registered else { return }
        enableRequested = value
        guard !value else { return }
        stopRefresh()
        password = ""; enabled = false; snapshot = nil; failure = nil
        if var config = configuration {
            config.enabled = false
            do { try store.save(config); configuration = config }
            catch { failure = .configuration }
        }
    }

    func saveAndRefresh() {
        guard registered, enableRequested, !isRunning else { return }
        do {
            let config = try DaouOfficeConfiguration(enabled: true, address: address, loginID: loginID)
            let oldPassword = try secrets.load(for: config.credentialKey)
            guard !password.isEmpty || oldPassword?.isEmpty == false else { throw PluginFailure.missingCredentials }
            let replacingPassword = !password.isEmpty
            if replacingPassword { try secrets.save(password, for: config.credentialKey) }
            do { try store.save(config) }
            catch {
                if replacingPassword {
                    if let oldPassword { try secrets.save(oldPassword, for: config.credentialKey) }
                    else { try secrets.remove(for: config.credentialKey) }
                }
                throw error
            }
            stopRefresh()
            configuration = config; address = config.baseURL.absoluteString; loginID = config.loginID
            password = ""; hasSavedPassword = true; enabled = true; snapshot = nil
            failure = nil; failures = 0
            connect(config)
            refresh()
        } catch { failure = error as? PluginFailure ?? .credentials }
    }

    private func connect(_ config: DaouOfficeConfiguration) {
        plugin.configure(makeClient(config, secrets))
        try? registry.activate(plugin.descriptor.id)
    }

    func refresh(reconnect: Bool = false) {
        guard canRefresh, let config = configuration else { return }
        if !registry.isEnabled(plugin.descriptor.id) || (reconnect && !captchaRequired) { connect(config) }
        perform(.refresh)
    }

    func submitCaptcha() {
        guard canSubmitCaptcha, let challenge = captchaChallenge else { return }
        let answer = captchaAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        captchaAnswer = ""
        perform(.submitCaptcha(answer, challenge.id))
    }

    func reloadCaptcha() {
        guard canReloadCaptcha, let challenge = captchaChallenge else { return }
        captchaAnswer = ""
        perform(.reloadCaptcha(challenge.id))
    }

    func cancelCaptcha() {
        guard captchaRequired else { return }
        stopRefresh()
        failure = nil
    }

    private func perform(_ operation: Operation) {
        isRunning = true; nextRunAt = nil; failure = nil; diagnostic = nil
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            var phase = operation
            do {
                switch operation {
                case .refresh: break
                case .submitCaptcha(let answer, let id):
                    try await self.plugin.submitCaptcha(answer, challengeID: id)
                case .reloadCaptcha(let id):
                    try await self.plugin.reloadCaptcha(challengeID: id)
                    guard self.generation == current, self.enabled, !Task.isCancelled else { return }
                    self.captchaChallenge = self.plugin.captchaChallenge
                    self.captchaRequired = self.plugin.requiresCaptcha
                    self.lastLoginDiagnostic = self.plugin.lastLoginDiagnostic
                    self.isRunning = false; self.task = nil
                    self.reportOutcome(operation)
                    return
                }
                // Authentication is complete; failures from here follow the data-refresh retry policy.
                phase = .refresh
                let value = try await self.registry.refresh(self.plugin.descriptor.id)
                guard self.generation == current, self.enabled, !Task.isCancelled else { return }
                self.snapshot = value; self.failures = 0
                self.diagnostic = nil; self.captchaChallenge = nil; self.captchaRequired = false; self.captchaAnswer = ""
                self.lastLoginDiagnostic = nil; self.captchaLoginRejected = false
                self.nextRunAt = Date().addingTimeInterval(15 * 60)
            } catch is CancellationError {
                guard self.generation == current else { return }
            } catch {
                guard self.generation == current, self.enabled, !Task.isCancelled else { return }
                let failure = error as? PluginFailure ?? .network
                self.failure = failure; self.failures += 1
                self.diagnostic = self.plugin.diagnostic
                self.lastLoginDiagnostic = self.plugin.lastLoginDiagnostic
                self.captchaChallenge = self.plugin.captchaChallenge
                self.captchaRequired = self.plugin.requiresCaptcha
                if case .submitCaptcha = phase, failure == .interactionRequired || failure == .authentication {
                    self.captchaLoginRejected = true
                }
                if case .refresh = phase,
                   !self.captchaRequired,
                   self.diagnostic?.path != "/api/portal/public/auth/captcha",
                   failure == .network || failure == .timeout {
                    self.nextRunAt = Date().addingTimeInterval([60.0, 300, 900][min(self.failures - 1, 2)])
                }
            }
            guard self.generation == current else { return }
            self.isRunning = false; self.task = nil
            self.reportOutcome(operation)
        }
    }

    private func reportOutcome(_ operation: Operation) {
        guard CommandLine.arguments.contains("--plugin-diagnostics") else { return }
        let action: String
        switch operation {
        case .refresh: action = "refresh"
        case .submitCaptcha: action = "captcha_submit"
        case .reloadCaptcha: action = "captcha_reload"
        }
        var value: [String: Any] = ["plugin": "daouoffice", "action": action,
            "captchaRequired": captchaRequired, "hasCaptchaImage": captchaChallenge != nil,
            "automaticRetryScheduled": nextRunAt != nil]
        if let diagnostic { value["requestPath"] = diagnostic.path; value["http"] = diagnostic.status }
        if let login = lastLoginDiagnostic {
            value["loginHTTP"] = login.status
            if let code = login.code { value["loginCode"] = code }
            if let flag = login.captchaRefreshRequired { value["captchaRefreshRequired"] = flag }
        }
        if let snapshot { value["leaveCount"] = snapshot.vacations.count; value["eventCount"] = snapshot.events.count }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }

    private func draftChanged() {
        guard captchaRequired || isRunning else { return }
        stopRefresh()
        failure = nil
    }

    private func stopRefresh() {
        generation += 1; task?.cancel(); task = nil
        if registered { registry.deactivate(plugin.descriptor.id) }
        isRunning = false; nextRunAt = nil; diagnostic = nil
        captchaChallenge = nil; captchaRequired = false; captchaAnswer = ""
        lastLoginDiagnostic = nil; captchaLoginRejected = false
    }
    func stop() { stopRefresh(); timer?.invalidate(); timer = nil; started = false }
}

extension DaouOfficePluginModel: PluginController {
    var descriptor: PluginDescriptor { PluginDescriptor(id: "daouoffice", name: localize("다우오피스", "Daouoffice")) }
    var changes: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
    var connectionState: PluginConnectionState {
        if isRunning { return .connecting }
        if failure != nil || captchaRequired { return .attention }
        if api.snapshot(for: descriptor.id) != nil && enabled { return .ready }
        return enableRequested ? .setup : .off
    }
    func refreshData() { refresh() }
}
