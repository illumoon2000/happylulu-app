import Foundation

/// Providers own usage/authentication transport. UI and history consume normalized snapshots.
public protocol UsageProvider: Sendable {
    var name: String { get }
    func fetch() async throws -> UsageSnapshot
    func makeLoginAttempt() -> (any UsageLoginAttempt)?
}

public protocol UsageLoginAttempt: AnyObject, Sendable {
    func login(openBrowser: @escaping @Sendable (URL) -> Void) async throws
    func cancel()
}

public struct CodexUsageProvider: UsageProvider {
    public let name = "Codex"
    public let executablePath: String
    public init(executablePath: String = "") { self.executablePath = executablePath }
    public func fetch() async throws -> UsageSnapshot { try await CodexClient().fetch(customPath: executablePath) }
    public func makeLoginAttempt() -> (any UsageLoginAttempt)? { CodexProviderLogin(path: executablePath) }
}

private final class CodexProviderLogin: UsageLoginAttempt, @unchecked Sendable {
    let path: String
    let attempt = CodexLoginAttempt()
    init(path: String) { self.path = path }
    func cancel() { attempt.cancel() }
    func login(openBrowser: @escaping @Sendable (URL) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await attempt.login(customPath: path, openBrowser: openBrowser)
        } onCancel: { self.cancel() }
    }
}
