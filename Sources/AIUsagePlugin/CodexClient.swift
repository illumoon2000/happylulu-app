import Foundation
import Darwin
import CryptoKit

public enum CodexExecutable {
    public static func resolve(customPath: String = "") throws -> URL {
        let fm = FileManager.default
        if !customPath.isEmpty {
            let path = (customPath as NSString).expandingTildeInPath
            guard fm.isExecutableFile(atPath: path), !isDirectory(path) else { throw UsageError.cliNotFound }
            return URL(fileURLWithPath: path)
        }
        let appPaths = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(fm.homeDirectoryForCurrentUser.path)/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/codex" }
        for path in appPaths + envPaths where fm.isExecutableFile(atPath: path) && !isDirectory(path) {
            return URL(fileURLWithPath: path)
        }
        throw UsageError.cliNotFound
    }

    private static func isDirectory(_ path: String) -> Bool {
        var flag: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &flag)
        return flag.boolValue
    }
}

public struct CodexClient: Sendable {
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = 25) { self.timeout = timeout }

    public func fetch(customPath: String = "") async throws -> UsageSnapshot {
        let request = CancellableUsageRequest()
        return try await withTaskCancellationHandler {
            let value = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try self.fetchBlocking(customPath: customPath, request: request)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: { request.cancel() }
    }

    public func fetchBlocking(customPath: String = "") throws -> UsageSnapshot {
        try fetchBlocking(customPath: customPath, request: CancellableUsageRequest())
    }

    private func fetchBlocking(customPath: String, request: CancellableUsageRequest) throws -> UsageSnapshot {
        let session = try RPCSession(executable: CodexExecutable.resolve(customPath: customPath), timeout: timeout)
        defer { session.close() }
        try request.attach(session)
        _ = try session.request(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "codex_usage_menu", "title": "Codex Usage", "version": "1.1.2"],
            "capabilities": ["experimentalApi": false]
        ])
        try session.send(["method": "initialized"])
        let accountResult = try session.request(id: 2, method: "account/read", params: ["refreshToken": false])
        guard let account = accountResult["account"] as? [String: Any] else { throw UsageError.notLoggedIn }
        guard let kind = account["type"] as? String, kind == "chatgpt" else { throw UsageError.unsupportedAccount }
        let result = try session.request(id: 3, method: "account/rateLimits/read")
        let data = try JSONSerialization.data(withJSONObject: result)
        let limits = try JSONDecoder().decode(RateLimitsResponse.self, from: data)
        // Persist only a fingerprint, never the email or authentication credentials.
        let accountKey = (account["email"] as? String).flatMap { email -> String? in
            guard !email.isEmpty else { return nil }
            let identity = email.lowercased() + "|" + (account["planType"] as? String ?? "")
            return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return UsageSnapshot(weekly: try limits.weeklyWindow(), accountKey: accountKey)
    }
}

private final class CancellableUsageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var session: RPCSession?
    func attach(_ session: RPCSession) throws {
        lock.lock()
        let wasCancelled = cancelled
        if !wasCancelled { self.session = session }
        lock.unlock()
        if wasCancelled { session.abort(); throw CancellationError() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let active = session
        lock.unlock()
        active?.abort()
    }
}

// A refresh owns one short-lived subprocess. Reads happen off the main thread;
// the watchdog covers initialization, network requests, and pipe reads together.
private final class RPCSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    private var finished = false
    private var timedOut = false
    private var watchdog: DispatchWorkItem?

    init(executable: URL, timeout: TimeInterval) throws {
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        let paths = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (paths + [environment["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment
        // A disconnected or cancelled server must not raise SIGPIPE in the host app.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let timer = DispatchWorkItem { [weak self] in self?.expire() }
        watchdog = timer
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
    }

    func send(_ object: [String: Any]) throws {
        try checkTimeout()
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(id: Int, method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        var request: [String: Any] = ["id": id, "method": method]
        if let params { request["params"] = params }
        try send(request)
        while true {
            let line = try readLine()
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                throw UsageError.invalidResponse
            }
            // Ignore server notifications. This client never starts a thread or turn.
            guard object["id"] as? Int == id else { continue }
            if let error = object["error"] as? [String: Any] {
                throw UsageError.server(error["message"] as? String ?? "RPC error")
            }
            guard let result = object["result"] as? [String: Any] else { throw UsageError.invalidResponse }
            return result
        }
    }

    func waitForLogin(id: String) throws {
        while true {
            let line = try readLine()
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                throw UsageError.invalidResponse
            }
            guard object["method"] as? String == "account/login/completed",
                  let params = object["params"] as? [String: Any], params["loginId"] as? String == id else { continue }
            guard params["success"] as? Bool == true else { throw UsageError.loginFailed }
            return
        }
    }

    func abort() {
        lock.lock()
        defer { lock.unlock() }
        if !finished, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func readLine() throws -> Data {
        while true {
            try checkTimeout()
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                return line
            }
            let chunk = output.fileHandleForReading.availableData
            try checkTimeout()
            guard !chunk.isEmpty else { throw UsageError.disconnected }
            buffer.append(chunk)
            guard buffer.count <= 4 * 1024 * 1024 else { throw UsageError.invalidResponse }
        }
    }

    private func checkTimeout() throws {
        lock.lock()
        let expired = timedOut
        lock.unlock()
        if expired { throw UsageError.timeout }
    }

    private func expire() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        timedOut = true
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func close() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        watchdog?.cancel()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        lock.unlock()
        // Reap the child with a bound, even if shutdown handlers ignore SIGTERM.
        for _ in 0..<20 {
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
}

/// Browser OAuth is owned by Codex. This app never handles passwords or tokens.
public final class CodexLoginAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var session: RPCSession?
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 180) { self.timeout = timeout }

    public func cancel() {
        lock.lock()
        cancelled = true
        let active = session
        lock.unlock()
        active?.abort()
    }

    public func login(customPath: String = "", openBrowser: @escaping @Sendable (URL) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.loginBlocking(customPath: customPath, openBrowser: openBrowser)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func loginBlocking(customPath: String, openBrowser: @escaping @Sendable (URL) -> Void) throws {
        let active = try RPCSession(executable: CodexExecutable.resolve(customPath: customPath), timeout: timeout)
        lock.lock()
        if cancelled { lock.unlock(); active.close(); throw CancellationError() }
        session = active
        lock.unlock()
        defer {
            active.close()
            lock.lock(); session = nil; lock.unlock()
        }
        do {
            _ = try active.request(id: 1, method: "initialize", params: [
                "clientInfo": ["name": "codex_usage_menu", "title": "Codex Usage", "version": "1.1.0"],
                "capabilities": ["experimentalApi": false]
            ])
            try active.send(["method": "initialized"])
            let result = try active.request(id: 2, method: "account/login/start", params: ["type": "chatgpt"])
            guard let id = result["loginId"] as? String,
                  let text = result["authUrl"] as? String, let url = URL(string: text),
                  url.scheme == "https", url.host != nil else { throw UsageError.invalidResponse }
            openBrowser(url)
            try active.waitForLogin(id: id)
        } catch {
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            if wasCancelled { throw CancellationError() }
            if case UsageError.timeout = error { throw UsageError.loginTimeout }
            throw error
        }
    }
}
