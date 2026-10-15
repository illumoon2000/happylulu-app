import Foundation
import AppPluginCore
@testable import DaouOfficePlugin

private final class CurlSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var number = 0
    private(set) var configs: [Data] = []
    func execute(_ config: Data) throws -> Data {
        lock.withLock {
            configs.append(config); number += 1
            let cookie: String
            switch number {
            case 1: cookie = "Set-Cookie: session=fixture-cookie; Path=/; Secure; HttpOnly\r\nSet-Cookie: foreign=fixture-foreign; Domain=other.invalid; Path=/; Secure\r\n"
            case 2: cookie = "Set-Cookie: session=; Max-Age=0; Path=/; Secure\r\n"
            default: cookie = ""
            }
            return Data(("HTTP/2 200\r\nContent-Type: application/json\r\n" + cookie + "\r\n{}").utf8)
        }
    }
    func captured() -> [Data] { lock.withLock { configs } }
}

func checkCurlTransport() async throws {
    let url = URL(string: "https://fixture.daouoffice.invalid/api/portal/public/auth/login")!
    let raw = Data(("HTTP/1.1 100 Continue\r\n\r\nHTTP/2 400\r\nContent-Type: application/json\r\n" +
        "Set-Cookie: first=fixture-one; Path=/; Secure; HttpOnly\r\n" +
        "Set-Cookie: second=fixture-two; Path=/api; Secure\r\n\r\n{\"code\":\"PORTAL-0012\"}").utf8)
    let parsed = try CurlHTTPResponseParser.parse(raw, url: url)
    require(parsed.response.statusCode == 400 && parsed.setCookies.count == 2, "Curl interim/duplicate cookie headers lost")
    require(parsed.body == Data(#"{"code":"PORTAL-0012"}"#.utf8), "Curl JSON body was changed")
    require(parsed.response.value(forHTTPHeaderField: "Content-Type") == "application/json", "Curl content type lost")
    require(DaouOfficeCurlTransport.quoted("fixture\"\\\n\r\t") == "\"fixture\\\"\\\\\\n\\r\\t\"", "Curl config escaping changed")
    for data in [Data("HTTP/1.1 200 OK\r\nNo-colon\r\n\r\n{}".utf8),
                 Data("HTTP/1.1 101 Switching Protocols\r\n\r\n".utf8),
                 Data(("HTTP/1.1 200 OK\r\nX-Fixture: " + String(repeating: "x", count: 65 * 1_024) + "\r\n\r\n{}").utf8),
                 Data(("HTTP/1.1 200 OK\r\n\r\n" + String(repeating: "x", count: 8 * 1_024 * 1_024 + 1)).utf8)] {
        do { _ = try CurlHTTPResponseParser.parse(data, url: url); fatalError("Invalid curl output accepted") }
        catch PluginFailure.unsupportedResponse {}
    }
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": parsed.setCookies[1]], for: url)
    require(cookies.count == 1 && DaouOfficeCurlTransport.matches(cookies[0], url: url), "Private curl cookie was not selected")
    require(!DaouOfficeCurlTransport.matches(cookies[0], url: URL(string: "https://fixture.daouoffice.invalid/apix")!), "Cookie path prefix leaked")
    require(!DaouOfficeCurlTransport.matches(cookies[0], url: URL(string: "https://other.invalid/api")!), "Cookie crossed domains")
    require(!DaouOfficeCurlTransport.matches(cookies[0], url: URL(string: "http://fixture.daouoffice.invalid/api")!), "Secure cookie used over HTTP")
    let hostCookie = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "host=fixture; Path=/; Secure"], for: url)[0]
    require(!DaouOfficeCurlTransport.matches(hostCookie, url: URL(string: "https://sub.fixture.daouoffice.invalid/api")!), "Host-only cookie reached a subdomain")
    let sequence = CurlSequence()
    let inMemory = DaouOfficeCurlTransport(fixtureExecutor: { try sequence.execute($0) })
    var request = URLRequest(url: url)
    request.httpMethod = "POST"; request.setValue("", forHTTPHeaderField: "X-Referer-Info")
    request.httpBody = Data(#"{"password":"fixture/secret","captcha":"fixture-captcha"}"#.utf8)
    _ = try await inMemory.send(request)
    _ = try await inMemory.send(request)
    _ = try await inMemory.send(request)
    let configs = sequence.captured().map { String(data: $0, encoding: .utf8)! }
    require(configs.count == 3 && configs[0].contains("header = \"X-Referer-Info;\""), "Curl explicit empty header was suppressed")
    require(configs[0].contains("data-binary = " + DaouOfficeCurlTransport.quoted(String(data: request.httpBody!, encoding: .utf8)!)), "Curl stdin config changed the JSON body")
    require(!configs[0].contains("Cookie:") && configs[1].contains("Cookie: session=fixture-cookie") && !configs[1].contains("fixture-foreign"), "Curl private cookie continuity failed")
    require(!configs[2].contains("Cookie:"), "Expired curl cookie was retained")
    require(configs.allSatisfy { $0.contains("proto = \"=https\"") && !$0.contains("location") && !$0.contains("cookie-jar") }, "Curl enabled redirects or disk cookies")
    let transport = DaouOfficeCurlTransport()
    do { _ = try await transport.send(URLRequest(url: URL(string: "http://127.0.0.1/fixture")!)); fatalError("Curl transport allowed HTTP") }
    catch PluginFailure.invalidAddress {}
    transport.cancel()
    do { _ = try await transport.send(URLRequest(url: url)); fatalError("Cancelled curl transport requested network") }
    catch is CancellationError {}
    print("PASS curl transport: bounded response parser, config escaping, private cookies, HTTPS and cancellation")
}
