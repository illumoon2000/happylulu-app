import Foundation
import Darwin
import AppPluginCore

/// Curl receives request values through a private stdin pipe. Cookies never leave this instance's memory.
public final class DaouOfficeCurlTransport: DaouOfficeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var busy = false
    private var process: Process?
    private var cookies: [HTTPCookie] = []
    private let fixtureExecutor: (@Sendable (Data) throws -> Data)?

    public init() { fixtureExecutor = nil }
    /// In-memory executable stand-in for offline checks; never exposed by app configuration.
    init(fixtureExecutor: @escaping @Sendable (Data) throws -> Data) { self.fixtureExecutor = fixtureExecutor }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached { try self.perform(request) }.value
        } onCancel: { self.cancel() }
    }

    public func cancel() {
        lock.withLock {
            cancelled = true; cookies.removeAll()
            if let process, process.isRunning { process.terminate() }
        }
    }

    deinit { cancel() }

    private func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else { throw PluginFailure.invalidAddress }
        let method = request.httpMethod ?? "GET"
        guard ["GET", "POST", "PUT"].contains(method) else { throw PluginFailure.unsupportedResponse }
        let requestCookies: [HTTPCookie] = try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            guard !busy else { throw PluginFailure.unavailable }
            busy = true
            cookies.removeAll { $0.expiresDate.map { $0 <= Date() } ?? false }
            return cookies.filter { Self.matches($0, url: url) }
        }
        defer { lock.withLock { process = nil; busy = false } }
        var lines = ["silent", "show-error", "max-time = 25", "proto = \"=https\"",
                     "suppress-connect-headers", "dump-header = \"-\"", "max-filesize = 8388608", "globoff",
                     "url = " + Self.quoted(url.absoluteString), "request = " + Self.quoted(method)]
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil,
                  !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else { throw PluginFailure.unsupportedResponse }
            if ["cookie", "content-length"].contains(name.lowercased()) { continue }
            // Curl's semicolon spelling sends an explicitly empty header instead of suppressing it.
            lines.append("header = " + Self.quoted(value.isEmpty ? name + ";" : name + ": " + value))
        }
        if let cookie = HTTPCookie.requestHeaderFields(with: requestCookies)["Cookie"], !cookie.isEmpty {
            guard !cookie.contains("\r"), !cookie.contains("\n"), !cookie.contains("\0") else { throw PluginFailure.unsupportedResponse }
            lines.append("header = " + Self.quoted("Cookie: " + cookie))
        }
        if let body = request.httpBody {
            guard body.count <= CurlHTTPResponseParser.bodyLimit,
                  let text = String(data: body, encoding: .utf8), !text.hasPrefix("@"), !text.contains("\0") else {
                throw PluginFailure.unsupportedResponse
            }
            lines.append("data-binary = " + Self.quoted(text))
        }
        let inputData = Data((lines.joined(separator: "\n") + "\n").utf8)
        let raw = try execute(inputData)
        let parsed = try CurlHTTPResponseParser.parse(raw, url: url)
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            for value in parsed.setCookies {
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: url) {
                    guard Self.accepts(cookie, from: url) else { continue }
                    cookies.removeAll { $0.name == cookie.name && Self.domain($0) == Self.domain(cookie) && $0.path == cookie.path }
                    if cookie.expiresDate.map({ $0 > Date() }) ?? true { cookies.append(cookie) }
                }
            }
            guard cookies.count <= 256 else { cookies.removeAll(); throw PluginFailure.unsupportedResponse }
        }
        return (parsed.body, parsed.response)
    }

    private func execute(_ inputData: Data) throws -> Data {
        if let fixtureExecutor {
            try lock.withLock { if cancelled { throw CancellationError() } }
            return try fixtureExecutor(inputData)
        }
        let input = Pipe(), output = Pipe(), child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        child.arguments = ["--disable", "--config", "-"]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        defer {
            try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            if child.isRunning { child.terminate(); child.waitUntilExit() }
        }
        do {
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                process = child
                try child.run()
            }
            // A failed curl parse cannot raise SIGPIPE in the hosting app.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try input.fileHandleForWriting.write(contentsOf: inputData)
            try input.fileHandleForWriting.close()
            var raw = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                guard raw.count + chunk.count <= CurlHTTPResponseParser.bodyLimit + CurlHTTPResponseParser.headerLimit else {
                    child.terminate(); throw PluginFailure.unsupportedResponse
                }
                raw.append(chunk)
            }
            child.waitUntilExit()
            try lock.withLock { if cancelled { throw CancellationError() } }
            guard child.terminationReason == .exit, child.terminationStatus == 0 else {
                if child.terminationStatus == 28 { throw PluginFailure.timeout }
                if child.terminationStatus == 63 { throw PluginFailure.unsupportedResponse }
                throw PluginFailure.network
            }
            return raw
        } catch is CancellationError { throw CancellationError() }
        catch let failure as PluginFailure { throw failure }
        catch {
            if lock.withLock({ cancelled }) { throw CancellationError() }
            throw PluginFailure.network
        }
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
    private static func domain(_ cookie: HTTPCookie) -> String {
        cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    static func accepts(_ cookie: HTTPCookie, from url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = domain(cookie)
        return host == domain || (domain.split(separator: ".").count >= 2 && host.hasSuffix("." + domain))
    }
    static func matches(_ cookie: HTTPCookie, url: URL) -> Bool {
        guard accepts(cookie, from: url), !cookie.isSecure || url.scheme?.lowercased() == "https",
              cookie.expiresDate.map({ $0 > Date() }) ?? true else { return false }
        if !cookie.domain.hasPrefix("."), url.host?.lowercased() != domain(cookie) { return false }
        let path = url.path.isEmpty ? "/" : url.path, prefix = cookie.path.isEmpty ? "/" : cookie.path
        return path == prefix || (path.hasPrefix(prefix) && (prefix.hasSuffix("/") || path.dropFirst(prefix.count).first == "/"))
    }
}

enum CurlHTTPResponseParser {
    static let bodyLimit = 8 * 1_024 * 1_024
    static let headerLimit = 64 * 1_024
    struct Response {
        let body: Data
        let response: HTTPURLResponse
        let setCookies: [String]
    }
    static func parse(_ raw: Data, url: URL) throws -> Response {
        guard raw.count <= bodyLimit + headerLimit else { throw PluginFailure.unsupportedResponse }
        var offset = 0, headerBytes = 0
        while offset < raw.count {
            guard let end = raw.range(of: Data("\r\n\r\n".utf8), in: offset..<raw.count),
                  end.upperBound - offset + headerBytes <= headerLimit,
                  let text = String(data: raw.subdata(in: offset..<end.lowerBound), encoding: .isoLatin1) else {
                throw PluginFailure.unsupportedResponse
            }
            headerBytes += end.upperBound - offset
            let lines = text.components(separatedBy: "\r\n"), status = lines[0].split(separator: " ")
            guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1", "HTTP/2", "HTTP/3"].contains(String(status[0])),
                  let code = Int(status[1]), (100...599).contains(code) else { throw PluginFailure.unsupportedResponse }
            var headers: [String: String] = [:], setCookies: [String] = []
            for line in lines.dropFirst() {
                guard let separator = line.firstIndex(of: ":") else { throw PluginFailure.unsupportedResponse }
                let name = String(line[..<separator]), value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                guard name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil,
                      !value.contains("\0") else { throw PluginFailure.unsupportedResponse }
                if name.lowercased() == "set-cookie" { setCookies.append(value) }
                if let previous = headers[name] { headers[name] = previous + ", " + value }
                else { headers[name] = value }
            }
            offset = end.upperBound
            if (100...199).contains(code) {
                guard code != 101 else { throw PluginFailure.unsupportedResponse }
                continue
            }
            guard raw.count - offset <= bodyLimit,
                  let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: String(status[0]), headerFields: headers) else {
                throw PluginFailure.unsupportedResponse
            }
            return Response(body: raw.subdata(in: offset..<raw.count), response: response, setCookies: setCookies)
        }
        throw PluginFailure.unsupportedResponse
    }
}
