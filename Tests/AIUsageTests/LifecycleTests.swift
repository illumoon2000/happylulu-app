import XCTest
import Combine
import AppPluginHost
@testable import AIUsagePlugin
@testable import AIUsageIntegration

private actor DeferredProvider: UsageProvider {
    nonisolated let name = "Fixture"
    nonisolated let loginAttempt: DeferredLogin?
    init(loginAttempt: DeferredLogin? = nil) { self.loginAttempt = loginAttempt }
    private var requests: [Int: CheckedContinuation<UsageSnapshot, Error>] = [:]
    private(set) var count = 0
    private(set) var cancellations = 0
    nonisolated func makeLoginAttempt() -> (any UsageLoginAttempt)? { loginAttempt }
    func fetch() async throws -> UsageSnapshot {
        count += 1
        let id = count
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { requests[id] = $0 }
        } onCancel: { Task { await self.cancelled() } }
    }
    private func cancelled() { cancellations += 1 }
    func finish(_ id: Int, used: Double = 28, error: UsageError? = nil) {
        guard let request = requests.removeValue(forKey: id) else { return }
        if let error { request.resume(throwing: error) }
        else {
            request.resume(returning: UsageSnapshot(weekly: UsageWindow(usedPercent: used,
                windowDurationMins: 10080, resetsAt: Date().addingTimeInterval(86400).timeIntervalSince1970), accountKey: "fixture-account"))
        }
    }
}

private actor DeferredLogin: UsageLoginAttempt {
    private var requests: [Int: CheckedContinuation<Void, Error>] = [:]
    private(set) var count = 0
    private(set) var cancellations = 0
    func login(openBrowser: @escaping @Sendable (URL) -> Void) async throws {
        count += 1
        let id = count
        try await withCheckedThrowingContinuation { requests[id] = $0 }
    }
    nonisolated func cancel() { Task { await self.cancelled() } }
    private func cancelled() { cancellations += 1 }
    func finish(_ id: Int, error: UsageError? = nil) {
        guard let request = requests.removeValue(forKey: id) else { return }
        if let error { request.resume(throwing: error) }
        else { request.resume() }
    }
}

private actor DeferredNotifications {
    private var pending: CheckedContinuation<Bool, Never>?
    private(set) var checks = 0
    private(set) var deliveries: [String] = []
    func authorization() async -> Bool {
        checks += 1
        return await withCheckedContinuation { pending = $0 }
    }
    func allow() { pending?.resume(returning: true); pending = nil }
    func deliver(_ body: String) { deliveries.append(body) }
}

@MainActor
final class LifecycleTests: XCTestCase {
    private func defaults() -> (String, UserDefaults) {
        let id = "HappyLulu.AIUsageTests." + UUID().uuidString
        return (id, UserDefaults(suiteName: id)!)
    }
    private func eventually(_ predicate: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !(await predicate()) {
            guard Date() < end else { XCTFail("Condition did not arrive"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testLoginKeepsPluginBusyThroughFollowUpRefresh() async throws {
        let (id, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: id) }
        let login = DeferredLogin(), provider = DeferredProvider(loginAttempt: login)
        let model = AIUsageModel(defaults: defaults, providerFactory: { _ in provider })
        let controller: any PluginController = model
        defer { model.stop() }
        model.setEnabled(true); model.start()
        try await eventually { await provider.count == 1 }; await provider.finish(1)
        try await eventually { !controller.isRunning }
        model.login()
        XCTAssertTrue(controller.isRunning, "The host must defer automatic updates while browser login is pending")
        try await eventually { await login.count == 1 }
        model.refreshData(); model.login()
        await login.finish(1)
        try await eventually { await provider.count == 2 }
        XCTAssertFalse(model.isLoggingIn)
        XCTAssertTrue(controller.isRunning, "The post-login refresh must remain protected")
        let loginCount = await login.count
        XCTAssertEqual(loginCount, 1)
        await provider.finish(2)
        try await eventually { !controller.isRunning }
    }

    func testFailedLoginReleasesPluginBusyState() async throws {
        let (id, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: id) }
        let login = DeferredLogin(), provider = DeferredProvider(loginAttempt: login)
        let model = AIUsageModel(defaults: defaults, providerFactory: { _ in provider })
        defer { model.stop() }
        model.setEnabled(true); model.start()
        try await eventually { await provider.count == 1 }; await provider.finish(1)
        try await eventually { !model.isRunning }
        model.login()
        XCTAssertTrue(model.isRunning)
        try await eventually { await login.count == 1 }; await login.finish(1, error: .loginFailed)
        try await eventually { !model.isLoggingIn }
        XCTAssertFalse(model.isRunning)
        XCTAssertNotNil(model.message)
    }

    func testCancelledLoginCannotClearNewLoginBusyState() async throws {
        let (id, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: id) }
        let login = DeferredLogin(), provider = DeferredProvider(loginAttempt: login)
        let model = AIUsageModel(defaults: defaults, providerFactory: { _ in provider })
        defer { model.stop() }
        model.setEnabled(true); model.start()
        try await eventually { await provider.count == 1 }; await provider.finish(1)
        try await eventually { !model.isRunning }
        model.login()
        try await eventually { await login.count == 1 }
        model.cancelLogin()
        XCTAssertFalse(model.isRunning)
        model.login()
        try await eventually { await login.count == 2 }
        await login.finish(1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.isLoggingIn)
        XCTAssertTrue(model.isRunning, "A cancelled attempt must not release the new login's update protection")
        await login.finish(2, error: .loginFailed)
        try await eventually { !model.isLoggingIn }
        XCTAssertFalse(model.isRunning)
    }

    func testDisablingDuringLoginReleasesBusyStateAndIgnoresLateCompletion() async throws {
        let (id, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: id) }
        let login = DeferredLogin(), provider = DeferredProvider(loginAttempt: login)
        let model = AIUsageModel(defaults: defaults, providerFactory: { _ in provider })
        model.setEnabled(true); model.start()
        try await eventually { await provider.count == 1 }; await provider.finish(1)
        try await eventually { !model.isRunning }
        model.login()
        try await eventually { await login.count == 1 }
        model.setEnabled(false)
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.isLoggingIn)
        try await eventually { await login.cancellations == 1 }
        await login.finish(1)
        try await Task.sleep(for: .milliseconds(30))
        let fetchCount = await provider.count
        XCTAssertEqual(fetchCount, 1)
        XCTAssertNil(model.snapshot)
    }

    func testNotificationRechecksThresholdAfterPermissionLookup() async throws {
        let (id, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: id) }
        var preferences = Preferences(); preferences.notificationsEnabled = true; preferences.notificationThreshold = 30
        defaults.set(try JSONEncoder().encode(preferences), forKey: "HappyLuluAIUsage.preferences.v1")
        let provider = DeferredProvider()
        let notifications = DeferredNotifications()
        let model = AIUsageModel(defaults: defaults, providerFactory: { _ in provider },
            notificationAuthorization: { await notifications.authorization() },
            notificationDelivery: { _, _, body in await notifications.deliver(body) })
        model.setEnabled(true); model.start()
        try await eventually { await provider.count == 1 }; await provider.finish(1, used: 75)
        try await eventually { await notifications.checks == 1 }
        model.updatePreferences { $0.notificationThreshold = 10 }
        await notifications.allow()
        try await eventually { !model.isRunning }
        let deliveries = await notifications.deliveries
        XCTAssertTrue(deliveries.isEmpty, "25% remaining must not trigger the newly selected 10% threshold: \(deliveries)")
        model.stop()
    }

    func testDisabledDoesNotQueryAndStartIsIdempotent() async throws {
        let (id, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: id) }
        let provider = DeferredProvider()
        let model = AIUsageModel(defaults: defaults, providerFactory: { _ in provider })
        model.start(); model.refreshData()
        let before = await provider.count
        XCTAssertEqual(before, 0)
        XCTAssertNil(model.menuBarItem)
        model.setEnabled(true); model.start(); model.start(); model.refreshData()
        try await eventually { await provider.count == 1 }
        await provider.finish(1)
        try await eventually { !model.isRunning }
        XCTAssertEqual(model.menuBarItem?.title, "Fixture 72%")
        model.stop()
    }
    func testHideCancelsAndLateResultCannotRestoreDisplayOrHistory() async throws {
        let (id, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: id) }
        let provider = DeferredProvider()
        let model = AIUsageModel(defaults: defaults, providerFactory: { _ in provider })
        model.setEnabled(true); model.start()
        try await eventually { await provider.count == 1 }
        model.setEnabled(false)
        try await eventually { await provider.cancellations == 1 }
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.menuBarItem)
        await provider.finish(1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(model.snapshot)
        XCTAssertNil(defaults.data(forKey: "HappyLuluAIUsage.history.v1"))
    }
    func testOldGenerationCannotOverwriteReenabledRequest() async throws {
        let (id, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: id) }
        let provider = DeferredProvider()
        let model = AIUsageModel(defaults: defaults, providerFactory: { _ in provider })
        model.setEnabled(true); model.start()
        try await eventually { await provider.count == 1 }
        model.setEnabled(false); model.setEnabled(true); model.start()
        try await eventually { await provider.count == 2 }
        await provider.finish(1, used: 99)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.isRunning)
        XCTAssertNil(model.snapshot)
        await provider.finish(2, used: 20)
        try await eventually { !model.isRunning }
        XCTAssertEqual(model.snapshot?.weekly.remainingPercent, 80)
        model.stop()
    }
    func testTransientErrorRetainsStaleValueButSignoutClearsIt() async throws {
        let (id, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: id) }
        let provider = DeferredProvider()
        let model = AIUsageModel(defaults: defaults, providerFactory: { _ in provider })
        model.setEnabled(true); model.start()
        try await eventually { await provider.count == 1 }; await provider.finish(1)
        try await eventually { !model.isRunning }
        model.refreshData()
        try await eventually { await provider.count == 2 }; await provider.finish(2, error: .timeout)
        try await eventually { !model.isRunning }
        XCTAssertEqual(model.menuBarItem?.title, "Fixture 72% ·")
        XCTAssertNotNil(model.snapshot)
        model.refreshData()
        try await eventually { await provider.count == 3 }; await provider.finish(3, error: .notLoggedIn)
        try await eventually { !model.isRunning }
        XCTAssertNil(model.snapshot)
        XCTAssertNil(defaults.data(forKey: "HappyLuluAIUsage.history.v1"))
        XCTAssertEqual(model.menuBarItem?.title, "Fixture —")
        model.stop()
    }
    func testPercentageOnlyLabelKeepsProviderAndMeaningForAccessibility() async throws {
        let (id, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: id) }
        let provider = DeferredProvider()
        let model = AIUsageModel(defaults: defaults, localize: { _, en in en }, providerFactory: { _ in provider })
        model.updatePreferences { $0.labelFormat = .percentage }
        model.setEnabled(true); model.start()
        try await eventually { await provider.count == 1 }; await provider.finish(1)
        try await eventually { !model.isRunning }
        XCTAssertEqual(model.menuBarItem?.title, "72%")
        XCTAssertEqual(model.menuBarItem?.accessibilityLabel, "Fixture weekly remaining 72%")
        model.refreshData()
        try await eventually { await provider.count == 2 }; await provider.finish(2, error: .timeout)
        try await eventually { !model.isRunning }
        XCTAssertTrue(model.menuBarItem?.accessibilityLabel.contains("previous reading") == true)
        model.stop()
    }

    func testPreferencesPersistWithoutTouchingAttendanceOrCodexUsageSettings() {
        let (id, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: id) }
        defaults.set("preserved", forKey: "preferences")
        defaults.set("attendance", forKey: "unrelated")
        let model = AIUsageModel(defaults: defaults)
        model.updatePreferences { $0.refreshMinutes = 10; $0.labelFormat = .percentage }
        let restored = AIUsageModel(defaults: defaults)
        XCTAssertEqual(restored.preferences.refreshMinutes, 10)
        XCTAssertEqual(restored.preferences.labelFormat, .percentage)
        XCTAssertFalse(restored.enabled)
        XCTAssertNil(restored.menuBarItem)
        XCTAssertEqual(defaults.string(forKey: "preferences"), "preserved")
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "attendance")
    }
    func testChangingExecutableCancelsPreviousProviderGeneration() async throws {
        let (id, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: id) }
        let provider = DeferredProvider()
        let model = AIUsageModel(defaults: defaults, providerFactory: { _ in provider })
        model.setEnabled(true); model.start()
        try await eventually { await provider.count == 1 }
        model.updatePreferences { $0.cliPath = "/fixture/new-codex" }
        try await eventually { await provider.count == 2 }
        await provider.finish(1, used: 99); await provider.finish(2, used: 10)
        try await eventually { !model.isRunning }
        XCTAssertEqual(model.snapshot?.weekly.remainingPercent, 90)
        XCTAssertEqual(model.preferences.cliPath, "/fixture/new-codex")
        model.stop()
    }
}
