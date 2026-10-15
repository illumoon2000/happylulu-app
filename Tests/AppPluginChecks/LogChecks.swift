import Foundation
import DaouOfficePlugin

func checkAPILogging() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HappyLulu-log-fixture-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("logs/fixture.log")
    let logger = DaouOfficeAPILog(fileURL: file, writesToStandardOutput: false)
    let rawURL = "https://fixture.invalid/gw/api/calendar/event?timeMin=2026-10-01T00:00:00.000+09:00&calendarIds%5B%5D=123"
    var request = URLRequest(url: URL(string: rawURL)!)
    request.setValue("fixture-request-cookie", forHTTPHeaderField: "Cookie")
    request.httpBody = Data(#"{"password":"fixture-request-password"}"#.utf8)
    let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/2", headerFields: ["Set-Cookie": "fixture-response-cookie"])!
    let rawBody = "{ \"code\": \"BAD_QUERY\", \"message\": \"timeMin cannot parse +09:00\" }\n"
    logger.record(request: request, data: Data(rawBody.utf8), response: response, duration: 0.02)
    var rows = try readLogFixture(file)
    require(rows[0]["url"] as? String == rawURL && rows[0]["responseBody"] as? String == rawBody, "Raw error JSON or plus-query bytes changed")
    require(rows[0]["status"] as? Int == 400 && rows[0]["method"] as? String == "GET", "API log lost method or status")
    let secrets = #"{"code":"BAD_QUERY","nested":{"password":"fixture-private-password","access_token":"fixture-private-access","refreshToken":"fixture-private-refresh","loginId":"fixture-private-login"},"rows":[{"CAPTCHAImage":"fixture-private-image","cookie":"fixture-private-cookie","authorization":"fixture-private-authorization","message":"Bearer fixture-private-bearer"}],"jwt":"eyJmaXh0dXJl.eyJwYXlsb2Fk.Zml4dHVyZXNpZw"}"#
    request = URLRequest(url: URL(string: "https://fixture.invalid/api?token=fixture-query-token&time=+09:00")!)
    logger.record(request: request, data: Data(secrets.utf8), response: response, duration: 0)
    let auth = URLRequest(url: URL(string: "https://fixture.invalid/api/portal/public/auth/login")!)
    logger.record(request: auth, data: Data(#"{"code":"PORTAL-0012","data":"fixture-auth-body","message":"fixture-auth-message"}"#.utf8), response: response, duration: 0)
    let bootstrap = URLRequest(url: URL(string: "https://fixture.invalid/login")!)
    logger.record(request: bootstrap, data: Data(#"{"message":"fixture-bootstrap-body"}"#.utf8), response: response, duration: 0)
    let success = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: [:])!
    logger.record(request: request, data: Data(#"{"code":"200","data":[{"title":"fixture-success-personal-value"}]}"#.utf8), response: success, duration: 0)
    rows = try readLogFixture(file)
    require(rows[2]["responseBody"] == nil && rows[2]["code"] as? String == "PORTAL-0012" && rows[3]["responseBody"] == nil, "Authentication or bootstrap body was logged")
    require(rows[4]["responseBody"] == nil && rows[4]["responseShape"] != nil, "Success logged personal response values")
    let text = try String(contentsOf: file, encoding: .utf8)
    for secret in ["fixture-private", "fixture-request", "fixture-response-cookie", "fixture-auth", "fixture-bootstrap", "fixture-query-token", "fixture-success-personal-value", "eyJmaXh0dXJl"] {
        require(!text.contains(secret), "API logger retained a fixture secret")
    }
    let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
    let directoryMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as! NSNumber
    require(fileMode.intValue == 0o600 && directoryMode.intValue == 0o700, "API log file permissions are not private")
    let largeBody = Data(("{\"message\":\"" + String(repeating: "x", count: 50_000) + "\"}").utf8)
    for _ in 0..<50 { logger.record(request: request, data: largeBody, response: response, duration: 0) }
    let previous = file.appendingPathExtension("previous")
    require(FileManager.default.fileExists(atPath: previous.path), "API log did not rotate")
    for url in [file, previous] {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        require((values[.size] as! NSNumber).intValue <= 1_024 * 1_024 && (values[.posixPermissions] as! NSNumber).intValue == 0o600, "Rotated API log exceeded its bound or lost privacy")
    }
    let files = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    require(files.count == 2, "API logger retained multiple prior files")
    print("PASS API logging: raw error/query preservation, recursive redaction, no auth/success bodies and bounded private files")
}

private func readLogFixture(_ file: URL) throws -> [[String: Any]] {
    try Data(contentsOf: file).split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
}
