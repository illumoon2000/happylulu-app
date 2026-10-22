import AppKit
import CryptoKit
import Foundation
import Network
import Security

public enum GoogleAuthorizationError: Error, LocalizedError, Sendable {
    case missingClientID
    case browserUnavailable
    case callbackUnavailable
    case cancelled
    case stateMismatch
    case responseMalformed
    case refreshTokenMissing

    public var errorDescription: String? {
        switch self {
        case .missingClientID: "Google 데스크톱 OAuth 클라이언트 ID가 필요합니다"
        case .browserUnavailable: "Google 로그인 브라우저를 열 수 없습니다"
        case .callbackUnavailable: "Google 로그인 응답을 받을 수 없습니다"
        case .cancelled: "Google 로그인이 취소되었습니다"
        case .stateMismatch: "Google 로그인 확인 값이 일치하지 않습니다"
        case .responseMalformed: "Google 로그인 응답을 읽을 수 없습니다"
        case .refreshTokenMissing: "Google 계정을 다시 연결해 주세요"
        }
    }
}

private struct GoogleTokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
}

@MainActor
private final class OAuthLoopbackReceiver {
    private let listener: NWListener
    private var ready: CheckedContinuation<UInt16, Error>?
    private var callback: CheckedContinuation<[String: String], Error>?
    private var pendingCallback: [String: String]?
    private var finished = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handle(state) }
            }
            listener.start(queue: .main)
        }
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue {
                ready?.resume(returning: port)
            } else {
                ready?.resume(throwing: GoogleAuthorizationError.callbackUnavailable)
            }
            ready = nil
        case .failed:
            ready?.resume(throwing: GoogleAuthorizationError.callbackUnavailable)
            ready = nil
            finish(error: GoogleAuthorizationError.callbackUnavailable)
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            Task { @MainActor in self?.handle(data, connection: connection) }
        }
    }

    private func handle(_ data: Data?, connection: NWConnection) {
        guard let data, let request = String(data: data, encoding: .utf8),
              let line = request.split(separator: "\r\n", maxSplits: 1).first,
              line.hasPrefix("GET "),
              let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost" + path),
              components.path == "/callback" else {
            reply(connection, status: "400 Bad Request", message: "Invalid sign-in response. / 잘못된 로그인 응답입니다.")
            return
        }
        let values = Dictionary(components.queryItems?.compactMap { item in
            item.value.map { (item.name, $0) }
        } ?? [], uniquingKeysWith: { first, _ in first })
        if let callback {
            self.callback = nil
            callback.resume(returning: values)
        } else {
            pendingCallback = values
        }
        reply(connection, status: "200 OK", message: "happylulu received the sign-in response. You can close this window. / happylulu 로그인 응답을 받았습니다. 이 창을 닫아도 됩니다.")
    }

    private func reply(_ connection: NWConnection, status: String, message: String) {
        let body = Data(message.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    func waitForCallback() async throws -> [String: String] {
        if let pendingCallback {
            self.pendingCallback = nil
            return pendingCallback
        }
        return try await withCheckedThrowingContinuation { continuation in
            callback = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
                Task { @MainActor in self?.finish(error: GoogleAuthorizationError.callbackUnavailable) }
            }
        }
    }

    private func finish(error: Error) {
        guard !finished else { return }
        finished = true
        callback?.resume(throwing: error)
        callback = nil
        listener.cancel()
    }

    func stop() {
        listener.cancel()
        callback?.resume(throwing: GoogleAuthorizationError.cancelled)
        callback = nil
        finished = true
    }
}

/// Desktop OAuth with PKCE and a loopback callback. The refresh token stays in Keychain.
public actor GoogleAuthorization: GoogleAccessTokenProvider {
    private let clientID: String
    private let credentialStore: CredentialStore
    private let http: CalendarHTTPClient
    private var cachedAccessToken: String?
    private var tokenExpiresAt: Date = .distantPast
    private let scopes = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.owned"
    ]

    public init(clientID: String, credentialStore: CredentialStore = CredentialStore(), http: CalendarHTTPClient = CalendarHTTPClient()) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.credentialStore = credentialStore
        self.http = http
    }

    private func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw GoogleAuthorizationError.responseMalformed
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func formBody(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    public func signIn() async throws {
        guard !clientID.isEmpty else { throw GoogleAuthorizationError.missingClientID }
        let receiver = try await OAuthLoopbackReceiver()
        let port = try await receiver.start()
        defer { Task { await receiver.stop() } }
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let verifier = try randomURLSafeString(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let state = try randomURLSafeString(byteCount: 24)
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url,
              await MainActor.run(body: { NSWorkspace.shared.open(url) }) else {
            throw GoogleAuthorizationError.browserUnavailable
        }
        let callback = try await receiver.waitForCallback()
        guard callback["state"] == state else { throw GoogleAuthorizationError.stateMismatch }
        guard let code = callback["code"] else { throw GoogleAuthorizationError.cancelled }
        let response = try await http.send(URL(string: "https://oauth2.googleapis.com/token")!, method: "POST", headers: [
            "Content-Type": "application/x-www-form-urlencoded"
        ], body: formBody([
            "client_id": clientID, "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirectURI
        ]))
        let tokens = try JSONDecoder().decode(GoogleTokenResponse.self, from: response.data)
        guard let refresh = tokens.refresh_token else { throw GoogleAuthorizationError.refreshTokenMissing }
        try credentialStore.save(refresh, for: "google.refreshToken")
        cachedAccessToken = tokens.access_token
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(tokens.expires_in))
    }

    public func accessToken() async throws -> String {
        guard !clientID.isEmpty else { throw GoogleAuthorizationError.missingClientID }
        if let cachedAccessToken, tokenExpiresAt.timeIntervalSinceNow > 60 { return cachedAccessToken }
        guard let refresh = try credentialStore.load(for: "google.refreshToken") else {
            throw GoogleAuthorizationError.refreshTokenMissing
        }
        let response: CalendarHTTPResult
        do {
            response = try await http.send(URL(string: "https://oauth2.googleapis.com/token")!, method: "POST", headers: [
                "Content-Type": "application/x-www-form-urlencoded"
            ], body: formBody([
                "client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"
            ]))
        } catch CalendarHTTPError.httpStatus(let status, _) where status == 400 || status == 401 {
            try? credentialStore.remove(for: "google.refreshToken")
            cachedAccessToken = nil
            tokenExpiresAt = .distantPast
            throw GoogleAuthorizationError.refreshTokenMissing
        }
        let tokens = try JSONDecoder().decode(GoogleTokenResponse.self, from: response.data)
        if let replacement = tokens.refresh_token { try credentialStore.save(replacement, for: "google.refreshToken") }
        cachedAccessToken = tokens.access_token
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(tokens.expires_in))
        return tokens.access_token
    }

    public func signOut() throws {
        try credentialStore.remove(for: "google.refreshToken")
        cachedAccessToken = nil
        tokenExpiresAt = .distantPast
    }
}
