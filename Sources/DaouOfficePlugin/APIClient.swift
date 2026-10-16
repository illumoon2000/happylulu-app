import Foundation
import AppPluginCore

public protocol DaouOfficeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func cancel()
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // An API redirect is an expired/unsupported session, never a place to forward credentials.
        completionHandler(nil)
    }
}

public final class DaouOfficeSessionTransport: DaouOfficeTransport, Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PluginFailure.network }
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? PluginFailure.timeout : PluginFailure.network
        }
    }
    public func cancel() { session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }
}

public actor DaouOfficeAPIClient {
    public nonisolated let configuration: DaouOfficeConfiguration
    private nonisolated let transport: any DaouOfficeTransport
    private let log: DaouOfficeAPILog?
    private let secrets: any PluginSecretStore
    private var authenticated = false
    private var bootstrapped = false
    private var companyID: Any?
    private var awaitingCaptcha = false
    private var pendingCaptcha: DaouOfficeCaptchaChallenge?
    private nonisolated let cancellationState = DaouOfficeCancellationState()
    private var operationID = UUID()
    private var operationInProgress = false
    public var captchaChallenge: DaouOfficeCaptchaChallenge? {
        cancellationState.isCancelled ? nil : pendingCaptcha
    }
    public var requiresCaptcha: Bool { !cancellationState.isCancelled && awaitingCaptcha }
    private var loginDiagnostic: DaouOfficeAPIDiagnostic?
    public var lastLoginDiagnostic: DaouOfficeAPIDiagnostic? {
        cancellationState.isCancelled ? nil : loginDiagnostic
    }
    public private(set) var diagnostic: DaouOfficeAPIDiagnostic?

    public init(configuration: DaouOfficeConfiguration, secrets: any PluginSecretStore = DaouOfficeSecretStore(),
                transport: any DaouOfficeTransport = DaouOfficeSessionTransport(), log: DaouOfficeAPILog? = nil) {
        self.configuration = configuration; self.secrets = secrets; self.transport = transport; self.log = log
    }
    public nonisolated func cancel() { cancellationState.cancel(); transport.cancel() }

    private func beginOperation() throws -> UUID {
        try Task.checkCancellation()
        guard !cancellationState.isCancelled else { throw CancellationError() }
        guard !operationInProgress else { throw PluginFailure.unavailable }
        operationID = UUID(); operationInProgress = true
        return operationID
    }
    private func checkOperation(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operationID == id, !cancellationState.isCancelled else { throw CancellationError() }
    }
    private func endOperation(_ id: UUID) { if operationID == id { operationInProgress = false } }

    private func request(_ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                         method: String? = nil, operation: UUID) async throws -> (Data, HTTPURLResponse) {
        try checkOperation(operation)
        diagnostic = nil
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              var parts = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw PluginFailure.invalidAddress
        }
        parts.path = path; parts.queryItems = query.isEmpty ? nil : query
        // This endpoint uses form-style query decoding, where a literal '+' becomes a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url, configuration.allows(url) else { throw PluginFailure.invalidAddress }
        var request = URLRequest(url: url)
        request.mainDocumentURL = configuration.baseURL
        request.httpMethod = method ?? (body == nil ? "GET" : "POST"); request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let isLogin = path == "/api/portal/public/auth/login"
        request.setValue(isLogin ? "" : configuration.baseURL.host, forHTTPHeaderField: "X-Referer-Info")
        request.setValue(configuration.baseURL.appendingPathComponent("login").absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(String(configuration.baseURL.absoluteString.dropLast()), forHTTPHeaderField: "Origin")
        let startedAt = Date()
        let (data, response) = try await transport.send(request)
        try checkOperation(operation)
        guard let responseURL = response.url, configuration.allows(responseURL) else { throw PluginFailure.invalidAddress }
        guard data.count <= 8 * 1_024 * 1_024 else { throw PluginFailure.unsupportedResponse }
        log?.record(request: request, data: data, response: response, duration: Date().timeIntervalSince(startedAt))
        diagnostic = DaouOfficeAPIDiagnostic(path: path, data: data, response: response)
        return (data, response)
    }

    private func check(_ data: Data, _ response: HTTPURLResponse) throws {
        let rawCode = try? DaouOfficeAPIParser.object(data)["code"]
        let code = rawCode.map { String(describing: $0) } ?? ""
        if ["PORTAL-0901", "PORTAL-0902", "ROUTE-0900", "ROUTE-0901", "ROUTE-0902", "ROUTE-0903", "ROUTE-0904", "ROUTE-0007", "PORTAL-0013", "PORTAL-0912",
            "PORTAL-0003", "PORTAL-0005", "PORTAL-0012"].contains(code) { throw PluginFailure.interactionRequired }
        if code.hasPrefix("PORTAL-") || code.hasPrefix("ROUTE-") { throw PluginFailure.authentication }
        if response.statusCode == 401 || response.statusCode == 403 || (300...399).contains(response.statusCode) {
            throw PluginFailure.authentication
        }
        guard (200...299).contains(response.statusCode) else {
            throw response.statusCode >= 500 || response.statusCode == 429 ? PluginFailure.network : PluginFailure.unsupportedResponse
        }
        if !code.isEmpty && code != "200" { throw PluginFailure.unsupportedResponse }
        guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("json") == true else {
            throw PluginFailure.unsupportedResponse
        }
    }

    private func login(operation: UUID) async throws {
        guard configuration.enabled else { throw PluginFailure.disabled }
        let password: String
        if let retained = cancellationState.retainedPassword { password = retained }
        else {
            guard let saved = try secrets.load(for: configuration.credentialKey), !saved.isEmpty else { throw PluginFailure.missingCredentials }
            try cancellationState.retainPassword(saved)
            password = saved
        }
        do {
            if !bootstrapped {
                let (_, pageResponse) = try await request("/login", operation: operation)
                guard (200...299).contains(pageResponse.statusCode) else {
                    throw pageResponse.statusCode >= 500 || pageResponse.statusCode == 429 ? PluginFailure.network : PluginFailure.unsupportedResponse
                }
                guard pageResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true else {
                    throw PluginFailure.unsupportedResponse
                }
                bootstrapped = true
            }
            let (companyData, companyResponse) = try await request("/api/portal/public/auth/company", operation: operation)
            try check(companyData, companyResponse)
            guard let payload = try DaouOfficeAPIParser.payload(companyData) as? [String: Any],
                  let companies = payload["companyList"] as? [[String: Any]], companies.count == 1,
                  let companyID = companies[0]["companyId"] else { throw PluginFailure.unsupportedResponse }
            _ = try DaouOfficeAPIParser.identifier(companyID)
            self.companyID = companyID
            let body = try JSONSerialization.data(withJSONObject: ["companyId": companyID, "loginId": configuration.loginID,
                "password": password, "captcha": "", "locale": "ko"], options: [.withoutEscapingSlashes])
            try await sendLogin(body, operation: operation)
        } catch {
            if !awaitingCaptcha { discardAuthenticationContext(unlessTemporary: error) }
            throw error
        }
    }

    private func discardAuthenticationContext(unlessTemporary error: Error? = nil) {
        if let failure = error as? PluginFailure, failure == .network || failure == .timeout { return }
        cancellationState.discardPassword()
        companyID = nil; awaitingCaptcha = false; pendingCaptcha = nil
    }

    private func sendLogin(_ body: Data, operation: UUID) async throws {
        let (data, response) = try await request("/api/portal/public/auth/login", body: body, operation: operation)
        // Keep the login rejection even when fetching its replacement image succeeds or fails.
        loginDiagnostic = diagnostic
        let code = (try? DaouOfficeAPIParser.object(data)["code"] as? String) ?? ""
        if ["PORTAL-0003", "PORTAL-0005", "PORTAL-0012"].contains(code) {
            authenticated = false; awaitingCaptcha = true; pendingCaptcha = nil
            try await fetchCaptcha(operation: operation)
            throw PluginFailure.interactionRequired
        }
        do { try check(data, response); _ = try DaouOfficeAPIParser.object(data) }
        catch {
            discardAuthenticationContext(unlessTemporary: error)
            throw error
        }
        try checkOperation(operation)
        authenticated = true; loginDiagnostic = nil; discardAuthenticationContext()
    }

    private func fetchCaptcha(operation: UUID) async throws {
        guard let companyID else { throw PluginFailure.interactionRequired }
        let body = try JSONSerialization.data(withJSONObject: ["companyId": companyID, "loginId": configuration.loginID], options: [.withoutEscapingSlashes])
        let (data, response) = try await request("/api/portal/public/auth/captcha", body: body,
                                               method: "PUT", operation: operation)
        try check(data, response)
        let challenge = try DaouOfficeCaptchaChallenge(data: data)
        try checkOperation(operation)
        pendingCaptcha = challenge
    }

    public func submitCaptcha(_ answer: String, challengeID: UUID) async throws {
        guard awaitingCaptcha, pendingCaptcha?.id == challengeID else { throw PluginFailure.interactionRequired }
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.count <= 128 else { throw PluginFailure.interactionRequired }
        let operation = try beginOperation(); defer { endOperation(operation) }
        guard let companyID, let password = cancellationState.retainedPassword, !password.isEmpty else {
            discardAuthenticationContext()
            throw PluginFailure.missingCredentials
        }
        let body = try JSONSerialization.data(withJSONObject: ["companyId": companyID, "loginId": configuration.loginID,
            "password": password, "captcha": answer, "locale": "ko"], options: [.withoutEscapingSlashes])
        try await sendLogin(body, operation: operation)
    }

    public func reloadCaptcha(challengeID: UUID) async throws {
        guard awaitingCaptcha, pendingCaptcha?.id == challengeID else { throw PluginFailure.interactionRequired }
        let operation = try beginOperation(); defer { endOperation(operation) }
        pendingCaptcha = nil
        try await fetchCaptcha(operation: operation)
    }

    private func get(_ path: String, query: [URLQueryItem] = [], operation: UUID) async throws -> Data {
        var (data, response) = try await request(path, query: query, operation: operation)
        let code = (try? DaouOfficeAPIParser.object(data)["code"] as? String) ?? ""
        if response.statusCode == 401 && code == "ROUTE-0006" {
            let (refreshData, refreshResponse) = try await request("/api/portal/public/auth/refresh/login", body: Data("{}".utf8), operation: operation)
            do { try check(refreshData, refreshResponse) }
            catch { authenticated = false; throw error }
            (data, response) = try await request(path, query: query, operation: operation)
        }
        do { try check(data, response) }
        catch PluginFailure.authentication { authenticated = false; throw PluginFailure.authentication }
        return data
    }

    public func refresh(now: Date = Date()) async throws -> PluginSnapshot {
        guard configuration.enabled else { throw PluginFailure.disabled }
        try Task.checkCancellation()
        guard !cancellationState.isCancelled else { throw CancellationError() }
        if awaitingCaptcha, pendingCaptcha != nil { throw PluginFailure.interactionRequired }
        let operation = try beginOperation(); defer { endOperation(operation) }
        if awaitingCaptcha {
            try await fetchCaptcha(operation: operation)
            throw PluginFailure.interactionRequired
        }
        if !authenticated { try await login(operation: operation) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let year = calendar.component(.year, from: now)
        guard let month = calendar.dateInterval(of: .month, for: now) else { throw PluginFailure.unavailable }
        let balance = try DaouOfficeAPIParser.balance(await get("/api/leave/normal/my/annual/summary", operation: operation))
        let upcoming = try DaouOfficeAPIParser.vacations(await get("/api/leave/normal/my/upcoming", operation: operation))
        let past = try DaouOfficeAPIParser.vacations(await get("/api/leave/normal/my/past/\(year)", operation: operation))
        guard let session = try DaouOfficeAPIParser.payload(await get("/gw/api/user/session", operation: operation)) as? [String: Any] else {
            throw PluginFailure.unsupportedResponse
        }
        let userID = try DaouOfficeAPIParser.identifier(session["id"])
        guard let calendars = try DaouOfficeAPIParser.payload(await get("/gw/api/calendar/user/\(userID)/calendar", operation: operation)) as? [[String: Any]] else {
            throw PluginFailure.unsupportedResponse
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = calendar.timeZone
        var query = [URLQueryItem(name: "timeMin", value: formatter.string(from: month.start)),
                     URLQueryItem(name: "timeMax", value: formatter.string(from: month.end.addingTimeInterval(-0.001))),
                     URLQueryItem(name: "includingAttendees", value: "false")]
        for item in calendars { query.append(URLQueryItem(name: "calendarIds[]", value: try DaouOfficeAPIParser.identifier(item["id"]))) }
        let events: [PluginCalendarEvent]
        if calendars.isEmpty { events = [] }
        else { events = try DaouOfficeAPIParser.events(await get("/gw/api/calendar/event", query: query, operation: operation), during: month) }
        var seen = Set<String>()
        let vacations = (upcoming + past).filter { seen.insert($0.id).inserted }
        let local = DateFormatter()
        local.calendar = calendar; local.timeZone = calendar.timeZone
        local.locale = Locale(identifier: "en_US_POSIX"); local.dateFormat = "yyyy-MM-dd"
        try checkOperation(operation)
        return PluginSnapshot(pluginID: "daouoffice", fetchedAt: Date(), leave: balance, vacations: vacations, events: events,
            coverage: PluginCoverage(calendarFrom: local.string(from: month.start),
                calendarThrough: local.string(from: month.end.addingTimeInterval(-0.001)), leaveHistoryIsLimited: true, leaveYear: year))
    }
}

@MainActor
public final class DaouOfficeAppPlugin: AppPlugin {
    public let descriptor = PluginDescriptor(id: "daouoffice", name: "Daouoffice", author: PluginAuthors.daouOffice)
    private var client: DaouOfficeAPIClient?
    public private(set) var diagnostic: DaouOfficeAPIDiagnostic?
    public private(set) var lastLoginDiagnostic: DaouOfficeAPIDiagnostic?
    public private(set) var captchaChallenge: DaouOfficeCaptchaChallenge?
    public private(set) var requiresCaptcha = false
    private var generation = 0
    public init() {}
    public func configure(_ client: DaouOfficeAPIClient) { cancel(); self.client = client; diagnostic = nil }
    private func captureState(from client: DaouOfficeAPIClient, generation current: Int) async throws {
        let value = await client.diagnostic
        let loginValue = await client.lastLoginDiagnostic
        let challenge = await client.captchaChallenge
        let required = await client.requiresCaptcha
        guard generation == current, !Task.isCancelled else { throw CancellationError() }
        diagnostic = value; lastLoginDiagnostic = loginValue; captchaChallenge = challenge; requiresCaptcha = required
    }
    public func refresh() async throws -> PluginSnapshot {
        guard let client else { throw PluginFailure.missingCredentials }
        let current = generation
        do {
            let snapshot = try await client.refresh()
            guard generation == current, !Task.isCancelled else { throw CancellationError() }
            diagnostic = nil; lastLoginDiagnostic = nil; captchaChallenge = nil; requiresCaptcha = false
            return snapshot
        } catch {
            try await captureState(from: client, generation: current)
            throw error
        }
    }
    public func submitCaptcha(_ answer: String, challengeID: UUID) async throws {
        guard let client else { throw PluginFailure.missingCredentials }
        let current = generation
        do {
            try await client.submitCaptcha(answer, challengeID: challengeID)
            try await captureState(from: client, generation: current)
        } catch {
            try await captureState(from: client, generation: current)
            throw error
        }
    }
    public func reloadCaptcha(challengeID: UUID) async throws {
        guard let client else { throw PluginFailure.missingCredentials }
        let current = generation
        do {
            try await client.reloadCaptcha(challengeID: challengeID)
            try await captureState(from: client, generation: current)
        } catch {
            try await captureState(from: client, generation: current)
            throw error
        }
    }
    public func cancel() { generation += 1; client?.cancel(); client = nil; diagnostic = nil; lastLoginDiagnostic = nil; captchaChallenge = nil; requiresCaptcha = false }
}
