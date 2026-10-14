import Foundation
import Darwin

/// Local API tracing: request headers/bodies and authentication response bodies are never logged.
public final class DaouOfficeAPILog: @unchecked Sendable {
    public static let standard = DaouOfficeAPILog(fileURL: defaultFileURL, writesToStandardOutput: true)
    public static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AfterSix/Plugins/Logs/daouoffice-api.log")
    private static let fileLimit = 1_024 * 1_024
    private static let errorBodyLimit = 64 * 1_024
    private let lock = NSLock()
    private let fileURL: URL?
    private let writesToStandardOutput: Bool

    public init(fileURL: URL?, writesToStandardOutput: Bool) {
        self.fileURL = fileURL; self.writesToStandardOutput = writesToStandardOutput
    }

    public func record(request: URLRequest, data: Data, response: HTTPURLResponse, duration: TimeInterval) {
        lock.withLock {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
            var row: [String: Any] = ["timestamp": formatter.string(from: Date()),
                "method": request.httpMethod ?? "GET", "url": Self.redactedURL(request.url),
                "status": response.statusCode, "responseBytes": data.count,
                "durationMs": duration.isFinite ? min(300_000, max(0, duration) * 1_000) : 0]
            if let contentType = response.value(forHTTPHeaderField: "Content-Type") { row["contentType"] = contentType }
            let json: Any?
            if data.count <= 8 * 1_024 * 1_024 { json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
            else { json = nil }
            let dictionary = json as? [String: Any]
            let rawCode = dictionary?["code"].map { String(describing: $0) }
            if let code = rawCode, code.range(of: #"^[A-Z0-9_-]{1,40}$"#, options: .regularExpression) != nil { row["code"] = code }
            let path = request.url?.path ?? ""
            let auth = path == "/login" || path.hasPrefix("/api/portal/public/auth/")
            if !auth {
                let failed = !(200...299).contains(response.statusCode) || (rawCode != nil && rawCode != "200")
                if failed, data.count <= Self.errorBodyLimit, let json, let original = String(data: data, encoding: .utf8) {
                    let (masked, changed) = Self.redact(json)
                    if !changed { row["responseBody"] = original }
                    else if let bytes = try? JSONSerialization.data(withJSONObject: masked, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]),
                            let text = String(data: bytes, encoding: .utf8) { row["responseBody"] = text }
                } else if !failed, let json { row["responseShape"] = Self.shape(json, depth: 0) }
            }
            guard let encoded = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]),
                  encoded.count < Self.fileLimit else { return }
            var line = encoded; line.append(10)
            if writesToStandardOutput {
                _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
                try? FileHandle.standardOutput.write(contentsOf: line)
            }
            if let fileURL { try? append(line, to: fileURL) }
        }
    }

    private static let sensitiveKeys: Set<String> = ["password", "passwd", "pwd", "token", "accesstoken", "refreshtoken",
        "authorization", "cookie", "setcookie", "captcha", "captchaanswer", "captchaimage", "loginid"]
    private static func sensitive(_ key: String) -> Bool {
        sensitiveKeys.contains(key.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }
    private static func redact(_ value: Any) -> (Any, Bool) {
        if let dictionary = value as? [String: Any] {
            var changed = false, result: [String: Any] = [:]
            for (key, item) in dictionary {
                if sensitive(key) { result[key] = "[redacted]"; changed = true }
                else {
                    let (masked, wasChanged) = redact(item)
                    result[key] = masked; changed = changed || wasChanged
                }
            }
            return (result, changed)
        }
        if let array = value as? [Any] {
            var changed = false
            let result = array.map { item in
                let (masked, wasChanged) = redact(item)
                changed = changed || wasChanged; return masked
            }
            return (result, changed)
        }
        if let string = value as? String {
            let bearer = string.replacingOccurrences(of: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, with: "Bearer [redacted]", options: .regularExpression)
            let jwt = bearer.replacingOccurrences(of: #"\b[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, with: "[redacted]", options: .regularExpression)
            return (jwt, jwt != string)
        }
        return (value, false)
    }
    private static func redactedURL(_ url: URL?) -> String {
        guard let url else { return "" }
        let original = url.absoluteString
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "[unavailable]" }
        let query = components.percentEncodedQuery
        var changed = false
        if let query {
            let parts = query.split(separator: "&", omittingEmptySubsequences: false).map { part -> String in
                let text = String(part), name = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if sensitive(name.removingPercentEncoding ?? name) { changed = true; return name + "=%5Bredacted%5D" }
                return text
            }
            if changed { components.percentEncodedQuery = parts.joined(separator: "&") }
        }
        if components.user != nil || components.password != nil { components.user = nil; components.password = nil; changed = true }
        return changed ? (components.string ?? "[unavailable]") : original
    }
    private static func shape(_ value: Any, depth: Int) -> Any {
        guard depth < 4 else { return "nested" }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for key in dictionary.keys.sorted().prefix(10) where key.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil {
                result[key] = shape(dictionary[key]!, depth: depth + 1)
            }
            return result
        }
        if let array = value as? [Any] {
            var result: [String: Any] = ["count": array.count]
            if let first = array.first { result["firstShape"] = shape(first, depth: depth + 1) }
            return result
        }
        if value is NSNull { return "null" }
        if value is String { return "string" }
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number" }
        return "unknown"
    }

    private enum LogFailure: Error { case file }
    private func append(_ line: Data, to url: URL) throws {
        guard url.isFileURL else { throw LogFailure.file }
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory,
              let mode = directoryAttributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else { throw LogFailure.file }
        var descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw LogFailure.file }
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else { throw LogFailure.file }
        guard fchmod(descriptor, 0o600) == 0 else { throw LogFailure.file }
        if attributes.st_size > Self.fileLimit {
            guard ftruncate(descriptor, 0) == 0 else { throw LogFailure.file }
        } else if attributes.st_size + Int64(line.count) > Self.fileLimit {
            Darwin.close(descriptor); descriptor = -1
            let previous = url.appendingPathExtension("previous")
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try FileManager.default.moveItem(at: url, to: previous)
            descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard descriptor >= 0, fchmod(descriptor, 0o600) == 0 else { throw LogFailure.file }
        }
        try line.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LogFailure.file }
                offset += count
            }
        }
    }
}
