import Foundation
import AppPluginCore
import DaouOfficePlugin

struct FixtureSecrets: PluginSecretStore {
    let password: String?
    func load(for key: String) throws -> String? { password }
    func save(_ password: String, for key: String) throws { fatalError("API must never save credentials") }
    func remove(for key: String) throws { fatalError("API must never remove credentials") }
}

final class MutableFixtureSecrets: PluginSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    private var count = 0
    init(_ value: String) { self.value = value }
    func load(for key: String) throws -> String? { lock.withLock { count += 1; return value } }
    func replace(_ value: String) { lock.withLock { self.value = value } }
    var loadCount: Int { lock.withLock { count } }
    func save(_ password: String, for key: String) throws { fatalError("API must never save credentials") }
    func remove(for key: String) throws { fatalError("API must never remove credentials") }
}

struct APIStep: Sendable {
    let path: String
    let json: String
    var status: Int = 200
    var method = "GET"
    var contentType = "application/json"
}

actor FixtureTransport: DaouOfficeTransport {
    private var steps: [APIStep]
    private var requests: [URLRequest] = []
    private let holdPath: String?
    private var heldContinuation: CheckedContinuation<Void, Never>?
    init(_ steps: [APIStep], holdPath: String? = nil) {
        self.steps = steps.first?.path == "/api/portal/public/auth/company"
            ? [APIStep(path: "/login", json: "<!doctype html><html></html>", contentType: "text/html; charset=utf-8")] + steps : steps
        self.holdPath = holdPath
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !steps.isEmpty else { fatalError("Unexpected network request") }
        let step = steps.removeFirst()
        require(request.url?.path == step.path, "Wrong API route")
        require(request.httpMethod == step.method, "Unexpected mutation")
        require(request.url?.user == nil && request.url?.password == nil, "Credentials in URL")
        requests.append(request)
        if request.url?.path == holdPath { await withCheckedContinuation { heldContinuation = $0 } }
        return (Data(step.json.utf8), HTTPURLResponse(url: request.url!, statusCode: step.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": step.contentType])!)
    }
    nonisolated func cancel() {}
    func remaining() -> Int { steps.count }
    func captured() -> [URLRequest] { requests }
    func isHeld() -> Bool { heldContinuation != nil }
    func releaseHeld() { heldContinuation?.resume(); heldContinuation = nil }
}

func checkAPIClient() async throws {
    let config = try DaouOfficeConfiguration(enabled: true, address: "https://example.daouoffice.com", loginID: "employee")
    let company = APIStep(path: "/api/portal/public/auth/company", json: #"{"data":{"companyList":[{"companyId":12}]}}"#)
    let login = APIStep(path: "/api/portal/public/auth/login", json: #"{"data":{}}"#, method: "POST")
    let reads = [
        APIStep(path: "/api/leave/normal/my/annual/summary", json: #"{"data":{"totalDays":7,"usedDays":4.5,"formattedRemain":"2.5d (20h 0m)"}}"#),
        APIStep(path: "/api/leave/normal/my/upcoming", json: #"{"data":{"elements":[]}}"#),
        APIStep(path: "/api/leave/normal/my/past/2026", json: #"{"data":{"elements":[]}}"#),
        APIStep(path: "/gw/api/user/session", json: #"{"code":"200","data":{"id":900}}"#),
        APIStep(path: "/gw/api/calendar/user/900/calendar", json: #"{"code":"200","data":[{"id":123}]}"#),
        APIStep(path: "/gw/api/calendar/event", json: #"{"code":"200","data":[]}"#)
    ]
    let transport = FixtureTransport([company, login] + reads + reads)
    let client = DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture-secret"), transport: transport)
    let now = try DaouOfficeAPIParser.date("2026-10-13T10:00:00+09:00")
    let first = try await client.refresh(now: now)
    _ = try await client.refresh(now: now)
    let remaining = await transport.remaining(), requests = await transport.captured()
    require(remaining == 0, "API sequence incomplete")
    require(requests.filter { $0.httpMethod == "POST" }.count == 1, "Every poll logs in again")
    require(requests[0].url?.path == "/login" && requests[1].url?.path == company.path, "Web login bootstrap ordering changed")
    let body = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
    require(body["password"] as? String == "fixture-secret" && body["companyId"] as? Int == 12, "Login contract changed")
    require(requests[2].value(forHTTPHeaderField: "X-Referer-Info") == "", "Login tenant header differs from frontend")
    require(requests[2].value(forHTTPHeaderField: "Referer") == "https://example.daouoffice.com/login", "Login referer differs from frontend")
    let items = URLComponents(url: requests[8].url!, resolvingAgainstBaseURL: false)!.queryItems!
    require(items.contains(URLQueryItem(name: "calendarIds[]", value: "123")), "Calendar access selection lost")
    require(items.contains(URLQueryItem(name: "includingAttendees", value: "false")), "Unneeded attendee data requested")
    require(first.coverage.calendarFrom == "2026-10-01" && first.coverage.calendarThrough == "2026-10-31", "Calendar range inaccurate")
    require(first.coverage.leaveYear == 2026, "Leave scope lost")
    try await checkCalendarMonthScope(config: config, company: company, login: login, reads: reads, now: now)
    try await checkCalendarReadRetry(config: config, company: company, login: login, reads: reads, now: now)
    for step in [APIStep(path: "/login", json: "{}"),
                 APIStep(path: "/login", json: "<html></html>", status: 302, contentType: "text/html"),
                 APIStep(path: "/login", json: String(repeating: "x", count: 8 * 1_024 * 1_024 + 1), contentType: "text/html")] {
        let rejected = FixtureTransport([step])
        do {
            _ = try await DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture"), transport: rejected).refresh(now: now)
            fatalError("Unsupported bootstrap page was accepted")
        } catch PluginFailure.unsupportedResponse {}
    }

    // The live company's public API returns this identifier as a string, not NSNumber.
    let stringCompany = APIStep(path: company.path, json: #"{"data":{"companyList":[{"companyId":"1476755976291233792"}]}}"#)
    let stringTransport = FixtureTransport([stringCompany, login] + reads)
    _ = try await DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture"), transport: stringTransport).refresh(now: now)
    let stringRequests = await stringTransport.captured()
    let stringBody = try JSONSerialization.jsonObject(with: stringRequests[2].httpBody!) as! [String: Any]
    require(stringBody["companyId"] as? String == "1476755976291233792", "String company ID lost its type or precision")

    let expired = FixtureTransport([company, login,
        APIStep(path: reads[0].path, json: #"{"code":"ROUTE-0006"}"#, status: 401),
        APIStep(path: "/api/portal/public/auth/refresh/login", json: #"{"data":{}}"#, method: "POST")] + reads)
    _ = try await DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture"), transport: expired).refresh(now: now)
    let expiredRemaining = await expired.remaining()
    require(expiredRemaining == 0, "Expired cookie did not refresh once")

    for code in ["PORTAL-0902", "PORTAL-0013", "PORTAL-0901"] {
        let challenge = FixtureTransport([company, APIStep(path: login.path, json: "{\"code\":\"\(code)\"}", status: 400, method: "POST")])
        do {
            _ = try await DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture"), transport: challenge).refresh(now: now)
            fatalError("Interactive authentication automated")
        } catch PluginFailure.interactionRequired {}
        let challengeRemaining = await challenge.remaining()
        require(challengeRemaining == 0, "Challenge looped or invalidated another session")
    }
    for code in ["ROUTE-0902", "ROUTE-0901", "ROUTE-0007"] {
        let challenge = FixtureTransport([company, login,
            APIStep(path: reads[0].path, json: "{\"code\":\"\(code)\"}", status: 401)])
        do {
            _ = try await DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture"), transport: challenge).refresh(now: now)
            fatalError("Protected API challenge attempted token refresh")
        } catch PluginFailure.interactionRequired {}
        let challengeRemaining = await challenge.remaining()
        require(challengeRemaining == 0, "Protected API challenge did not stop")
    }
    for code in ["ROUTE-0006", "PORTAL-0016"] {
        let rejected = FixtureTransport([company, APIStep(path: login.path,
            json: "{\"code\":\"\(code)\"}", method: "POST")])
        do {
            _ = try await DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture"), transport: rejected).refresh(now: now)
            fatalError("HTTP 200 vendor login failure was accepted")
        } catch PluginFailure.authentication {}
    }
    let missing = FixtureTransport([])
    do {
        _ = try await DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: nil), transport: missing).refresh(now: now)
        fatalError("Missing password accepted")
    } catch PluginFailure.missingCredentials {}
    var disabled = config; disabled.enabled = false
    do {
        _ = try await DaouOfficeAPIClient(configuration: disabled, secrets: FixtureSecrets(password: "fixture"), transport: missing).refresh(now: now)
        fatalError("Disabled plugin requested data")
    } catch PluginFailure.disabled {}
    let malformed = FixtureTransport([company, login, APIStep(path: reads[0].path,
        json: #"{"data":{"email":"private@example.invalid","password":"private-fixture-value"}}"#)])
    let diagnosticClient = DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture"), transport: malformed)
    do { _ = try await diagnosticClient.refresh(now: now); fatalError("Malformed response was published") }
    catch PluginFailure.unsupportedResponse {}
    let diagnostic = await diagnosticClient.diagnostic
    require(diagnostic?.path == reads[0].path && diagnostic?.status == 200, "Failed route diagnostic lost")
    require(diagnostic?.fields == ["email", "password"], "Diagnostic stored values instead of field names")
    require(!(diagnostic?.fields.joined() ?? "").contains("private"), "Private data leaked into diagnostic")
    try await checkCaptchaClient(config: config, company: stringCompany, login: login, reads: reads, now: now)
    print("PASS API client: tenant login, reused session, cookie refresh, read-only queries, scope, challenges and opt-in")
}

private func checkCalendarMonthScope(config: DaouOfficeConfiguration, company: APIStep, login: APIStep,
                                     reads: [APIStep], now: Date) async throws {
    // The live October response mixes these lunar reference dates with expanded occurrences.
    let raw = #"""
    {"code":"200","data":[
      {"id":"1","calendarId":"123","summary":"설날","type":"holiday","lunar":true,"recurrence":"FREQ=YEARLY;BYMONTH=1;BYMONTHDAY=1;UNTIL=20261231","startTime":"1970-02-06T00:00:00.000+09:00","endTime":"1970-02-06T00:00:00.000+09:00","timeType":"allday"},
      {"id":"2","calendarId":"123","summary":"-설날","type":"holiday","lunar":true,"startTime":"2027-02-06T00:00:00.000+09:00","endTime":"2027-02-06T00:00:00.000+09:00","timeType":"allday"},
      {"id":"3","calendarId":"123","summary":"개천절","type":"holiday","startTime":"2026-10-03T00:00:00.000+09:00","endTime":"2026-10-03T00:00:00.000+09:00","timeType":"allday"},
      {"id":"4","calendarId":"123","summary":"월초","startTime":"2026-10-01T00:00:00.000+09:00","endTime":"2026-10-01T00:00:00.000+09:00","timeType":"allday"},
      {"id":"5","calendarId":"123","summary":"월말","startTime":"2026-10-31T23:00:00.000+09:00","endTime":"2026-11-01T01:00:00.000+09:00","timeType":"timed"},
      {"id":"6","calendarId":"123","summary":"다음 달","startTime":"2026-11-01T00:00:00.000+09:00","endTime":"2026-11-01T00:00:00.000+09:00","timeType":"allday"},
      {"id":"7","calendarId":"123","summary":"지난 달","startTime":"2026-09-30T23:00:00.000+09:00","endTime":"2026-10-01T00:00:00.000+09:00","timeType":"timed"},
      {"id":"8","calendarId":"123","summary":"걸친 일정","startTime":"2026-09-30T23:00:00.000+09:00","endTime":"2026-10-01T01:00:00.000+09:00","timeType":"timed"},
      {"id":"9","calendarId":"123","summary":"반복","startTime":"2026-10-12T11:00:00.000+09:00","endTime":"2026-10-12T12:00:00.000+09:00","timeType":"timed"},
      {"id":"9","calendarId":"123","summary":"반복","startTime":"2026-10-19T11:00:00.000+09:00","endTime":"2026-10-19T12:00:00.000+09:00","timeType":"timed"},
      {"id":"9","calendarId":"123","summary":"반복","startTime":"2026-10-19T11:00:00.000+09:00","endTime":"2026-10-19T12:00:00.000+09:00","timeType":"timed"}
    ]}
    """#
    var calendarReads = reads
    calendarReads[5] = APIStep(path: reads[5].path, json: raw)
    let transport = FixtureTransport([company, login] + calendarReads)
    let snapshot = try await DaouOfficeAPIClient(configuration: config,
        secrets: FixtureSecrets(password: "fixture"), transport: transport).refresh(now: now)
    require(snapshot.events.map(\.title) == ["걸친 일정", "월초", "개천절", "반복", "반복", "월말"],
        "Calendar snapshot exposes lunar reference dates or events outside its requested month")
    let actualHoliday = try DaouOfficeAPIParser.date("2026-10-03T00:00:00+09:00")
    require(snapshot.events[2].start == actualHoliday,
        "Calendar occurrence was changed to an invented date")
    print("PASS calendar month: lunar reference dates excluded, exact boundaries, overlapping events and repeated occurrences preserved")
}

private func checkCalendarReadRetry(config: DaouOfficeConfiguration, company: APIStep, login: APIStep,
                                    reads: [APIStep], now: Date) async throws {
    var calendarReads = reads
    calendarReads[4] = APIStep(path: reads[4].path,
        json: #"{"code":"200","data":[{"id":123},{"id":456}]}"#)
    var rejectedReads = calendarReads
    rejectedReads[5] = APIStep(path: reads[5].path, json: #"{"code":"BAD_REQUEST"}"#, status: 400)
    let transport = FixtureTransport([company, login] + rejectedReads + calendarReads)
    let client = DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture"), transport: transport)
    do { _ = try await client.refresh(now: now); fatalError("Calendar HTTP 400 was published as success") }
    catch PluginFailure.unsupportedResponse {}
    let beforeRetry = await transport.captured()
    let snapshot = try await client.refresh(now: now)
    let requests = await transport.captured(), remaining = await transport.remaining()
    require(remaining == 0 && snapshot.pluginID == "daouoffice", "Calendar retry did not complete the same client's read sequence")
    require(beforeRetry.filter { $0.httpMethod == "POST" }.count == 1 && requests.filter { $0.httpMethod == "POST" }.count == 1,
        "Retrying a calendar read failure sent another password login")
    let retryRequests = Array(requests.dropFirst(beforeRetry.count))
    require(retryRequests.allSatisfy { $0.httpMethod == "GET" } && retryRequests.map { $0.url!.path } == calendarReads.map(\.path),
        "Calendar retry replaced authentication instead of repeating read-only requests")
    let eventRequests = requests.filter { $0.url?.path == reads[5].path }
    require(eventRequests.count == 2, "Calendar failure was not retried once")
    for request in eventRequests {
        let url = request.url!
        let encodedURL = url.absoluteString.uppercased()
        let hasEncodedOffset = encodedURL.contains("%2B09:00") || encodedURL.contains("%2B09%3A00")
        require(hasEncodedOffset && !encodedURL.contains("+"), "Calendar URL contains a form-decoded space in its positive timezone offset")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        require(items.first { $0.name == "timeMin" }?.value == "2026-10-01T00:00:00.000+09:00" &&
                items.first { $0.name == "timeMax" }?.value == "2026-10-31T23:59:59.999+09:00",
            "Percent-decoded calendar boundaries differ from the exact Seoul range")
        let calendarIDs = items.filter { $0.name == "calendarIds[]" }.map(\.value)
        require(calendarIDs == ["123", "456"], "Repeated calendarIds[] were collapsed or changed during URL encoding")
    }
    print("PASS calendar API: HTTP 400 read retry reuses authentication, encodes timezone offsets and preserves repeated calendar IDs")
}

private let fixturePNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

private func checkCaptchaClient(config: DaouOfficeConfiguration, company: APIStep, login: APIStep,
                                reads: [APIStep], now: Date) async throws {
    let captcha = APIStep(path: "/api/portal/public/auth/captcha", json: "{\"data\":{\"captchaImage\":\"\(fixturePNG)\"}}", method: "PUT")
    for code in ["PORTAL-0003", "PORTAL-0005", "PORTAL-0012"] {
        let transport = FixtureTransport([company, APIStep(path: login.path,
            json: "{\"code\":\"\(code)\"}", status: 400, method: "POST"), captcha, login] + reads)
        let client = DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture-secret"), transport: transport)
        do { _ = try await client.refresh(now: now); fatalError("CAPTCHA challenge was ignored") }
        catch PluginFailure.interactionRequired {}
        guard let challenge = await client.captchaChallenge else { fatalError("CAPTCHA image was not exposed") }
        require(challenge.imageData == Data(base64Encoded: fixturePNG), "CAPTCHA image changed")
        let before = await transport.captured().count
        do { _ = try await client.refresh(now: now); fatalError("Pending CAPTCHA was bypassed") }
        catch PluginFailure.interactionRequired {}
        do { try await client.submitCaptcha("human-answer", challengeID: UUID()); fatalError("Stale CAPTCHA answer was sent") }
        catch PluginFailure.interactionRequired {}
        let afterPending = await transport.captured().count
        require(afterPending == before, "Pending or stale CAPTCHA triggered another login")
        try await client.submitCaptcha("human-answer", challengeID: challenge.id)
        let cleared = await client.captchaChallenge
        require(cleared == nil, "Successful CAPTCHA was retained")
        _ = try await client.refresh(now: now)
        let requests = await transport.captured()
        let remaining = await transport.remaining()
        require(remaining == 0, "CAPTCHA continuation sequence incomplete")
        require(requests.filter { $0.url?.path == company.path }.count == 1, "CAPTCHA continuation replaced the login session")
        let captchaBody = try JSONSerialization.jsonObject(with: requests[3].httpBody!) as! [String: Any]
        let answerBody = try JSONSerialization.jsonObject(with: requests[4].httpBody!) as! [String: Any]
        require(captchaBody["companyId"] as? String == "1476755976291233792" && captchaBody["loginId"] as? String == "employee", "CAPTCHA tenant identity changed")
        require(requests[3].value(forHTTPHeaderField: "X-Referer-Info") == "example.daouoffice.com", "CAPTCHA tenant header missing")
        require(answerBody["captcha"] as? String == "human-answer" && answerBody["password"] as? String == "fixture-secret", "Human CAPTCHA was not sent once")
        require(answerBody["companyId"] as? String == "1476755976291233792", "CAPTCHA continuation changed company ID type")
    }

    let challengeLogin = APIStep(path: login.path, json: #"{"code":"PORTAL-0003"}"#, status: 400, method: "POST")
    let wrongAnswer = APIStep(path: login.path,
        json: #"{"code":"PORTAL-0012","data":{"loginId":"private-person","needCaptchaRequest":true}}"#, status: 400, method: "POST")
    let replacementTransport = FixtureTransport([company, challengeLogin, captcha, wrongAnswer, captcha, captcha, login] + reads)
    let replacementClient = DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture-secret"), transport: replacementTransport)
    do { _ = try await replacementClient.refresh(now: now); fatalError("CAPTCHA challenge was ignored") }
    catch PluginFailure.interactionRequired {}
    guard let old = await replacementClient.captchaChallenge else { fatalError("First CAPTCHA missing") }
    do { try await replacementClient.submitCaptcha("wrong-human-answer", challengeID: old.id); fatalError("Incorrect CAPTCHA was accepted") }
    catch PluginFailure.interactionRequired {}
    guard let replacement = await replacementClient.captchaChallenge else { fatalError("Replacement CAPTCHA missing") }
    require(replacement.id != old.id, "Incorrect CAPTCHA retained the old challenge ID")
    let diagnostic = await replacementClient.diagnostic
    let rejectedLogin = await replacementClient.lastLoginDiagnostic
    require(rejectedLogin?.path == login.path && rejectedLogin?.status == 400 && rejectedLogin?.code == "PORTAL-0012", "Login rejection was replaced by image diagnostics")
    require(rejectedLogin?.captchaRefreshRequired == true, "Server CAPTCHA refresh flag was lost")
    require(!(rejectedLogin?.fields.joined() ?? "").contains("private-person"), "Personal response value leaked into login diagnostics")
    require(diagnostic?.fields == ["captchaImage"], "CAPTCHA diagnostic schema changed")
    require(!(diagnostic?.fields.joined() ?? "").contains(fixturePNG), "CAPTCHA bytes leaked into diagnostics")
    do { try await replacementClient.submitCaptcha("stale-answer", challengeID: old.id); fatalError("Old CAPTCHA was submitted again") }
    catch PluginFailure.interactionRequired {}
    try await replacementClient.reloadCaptcha(challengeID: replacement.id)
    guard let reloaded = await replacementClient.captchaChallenge else { fatalError("Reloaded CAPTCHA missing") }
    require(reloaded.id != replacement.id, "CAPTCHA reload reused its identity")
    try await replacementClient.submitCaptcha("correct-human-answer", challengeID: reloaded.id)
    let clearedLoginDiagnostic = await replacementClient.lastLoginDiagnostic
    require(clearedLoginDiagnostic == nil, "Successful authentication kept the last rejection")
    _ = try await replacementClient.refresh(now: now)
    let replacementRequests = await replacementTransport.captured(), replacementRemaining = await replacementTransport.remaining()
    require(replacementRemaining == 0, "Incorrect/reloaded CAPTCHA sequence incomplete")
    require(replacementRequests.filter { $0.httpMethod == "POST" }.count == 3, "CAPTCHA answers were automatically retried")

    let failedFetch = APIStep(path: captcha.path, json: #"{"code":"temporary"}"#, status: 503, method: "PUT")
    let recoveryTransport = FixtureTransport([company, challengeLogin, failedFetch, captcha])
    let recoveryClient = DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture-secret"), transport: recoveryTransport)
    do { _ = try await recoveryClient.refresh(now: now); fatalError("CAPTCHA fetch failure was ignored") }
    catch PluginFailure.network {}
    let pendingWithoutImage = await recoveryClient.requiresCaptcha, missingImage = await recoveryClient.captchaChallenge
    require(pendingWithoutImage && missingImage == nil, "Failed CAPTCHA fetch lost pending state")
    let recoveryRejectedLogin = await recoveryClient.lastLoginDiagnostic, recoveryImageFailure = await recoveryClient.diagnostic
    require(recoveryRejectedLogin?.path == login.path && recoveryRejectedLogin?.code == "PORTAL-0003", "Image failure erased its login rejection")
    require(recoveryImageFailure?.path == captcha.path && recoveryImageFailure?.status == 503, "Image failure diagnostic was replaced")
    do { _ = try await recoveryClient.refresh(now: now); fatalError("CAPTCHA recovery skipped human interaction") }
    catch PluginFailure.interactionRequired {}
    let recoveryRequests = await recoveryTransport.captured(), recoveryChallenge = await recoveryClient.captchaChallenge
    require(recoveryChallenge != nil, "Explicit CAPTCHA fetch recovery failed")
    require(recoveryRequests.filter { $0.httpMethod == "POST" }.count == 1, "CAPTCHA fetch failure caused a fresh login")

    let slashConfig = try DaouOfficeConfiguration(enabled: true, address: "https://example.daouoffice.com/", loginID: "employee/fixture")
    let mutableSecrets = MutableFixtureSecrets("initial/secret")
    let contextTransport = FixtureTransport([company, challengeLogin, captcha, login] + reads +
        [APIStep(path: reads[0].path, json: #"{"code":"PORTAL-0016"}"#, status: 401), company, login] + reads)
    let contextClient = DaouOfficeAPIClient(configuration: slashConfig, secrets: mutableSecrets, transport: contextTransport)
    do { _ = try await contextClient.refresh(now: now); fatalError("Context CAPTCHA was ignored") }
    catch PluginFailure.interactionRequired {}
    guard let contextChallenge = await contextClient.captchaChallenge else { fatalError("Context CAPTCHA missing") }
    mutableSecrets.replace("changed/secret")
    try await contextClient.submitCaptcha("human/answer", challengeID: contextChallenge.id)
    _ = try await contextClient.refresh(now: now)
    let contextRequests = await contextTransport.captured()
    let continuedBody = try JSONSerialization.jsonObject(with: contextRequests[4].httpBody!) as! [String: Any]
    require(continuedBody["password"] as? String == "initial/secret" && mutableSecrets.loadCount == 1, "CAPTCHA continuation re-read a changed credential")
    require(String(data: contextRequests[2].httpBody!, encoding: .utf8)?.contains("initial/secret") == true &&
        String(data: contextRequests[4].httpBody!, encoding: .utf8)?.contains("human/answer") == true, "JSON login body escapes slashes differently from the frontend")
    do { _ = try await contextClient.refresh(now: now); fatalError("Expired authentication was ignored") }
    catch PluginFailure.authentication {}
    _ = try await contextClient.refresh(now: now)
    let resumedRequests = await contextTransport.captured()
    let resumedLogin = resumedRequests.last { $0.url?.path == login.path }!
    let resumedBody = try JSONSerialization.jsonObject(with: resumedLogin.httpBody!) as! [String: Any]
    require(resumedBody["password"] as? String == "changed/secret" && mutableSecrets.loadCount == 2, "Successful authentication retained the discarded credential context")
    require(resumedRequests.filter { $0.url?.path == "/login" }.count == 1, "The same session bootstrapped again")

    for code in ["PORTAL-0016", "PORTAL-0902"] {
        let rejected = FixtureTransport([company, challengeLogin, captcha,
            APIStep(path: login.path, json: "{\"code\":\"\(code)\",\"data\":{\"needCaptchaRequest\":1}}", status: 400, method: "POST")])
        let client = DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture"), transport: rejected)
        do { _ = try await client.refresh(now: now); fatalError("CAPTCHA was ignored") }
        catch PluginFailure.interactionRequired {}
        guard let challenge = await client.captchaChallenge else { fatalError("CAPTCHA missing") }
        do { try await client.submitCaptcha("human-answer", challengeID: challenge.id); fatalError("Non-CAPTCHA auth failure was accepted") }
        catch PluginFailure.authentication where code == "PORTAL-0016" {}
        catch PluginFailure.interactionRequired where code == "PORTAL-0902" {}
        let pending = await client.requiresCaptcha, image = await client.captchaChallenge, diagnostic = await client.lastLoginDiagnostic
        require(!pending && image == nil && diagnostic?.code == code, "Non-CAPTCHA failure was mislabeled as a CAPTCHA")
        require(diagnostic?.captchaRefreshRequired == nil, "Numeric CAPTCHA flag was mistaken for a boolean")
    }

    let invalidImages = ["invalid-base64", Data([0, 1, 2]).base64EncodedString(), Data(repeating: 0, count: 512 * 1_024 + 1).base64EncodedString()]
    for encoded in invalidImages {
        let transport = FixtureTransport([company, challengeLogin,
            APIStep(path: captcha.path, json: "{\"data\":{\"captchaImage\":\"\(encoded)\"}}", method: "PUT")])
        let client = DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture-secret"), transport: transport)
        do { _ = try await client.refresh(now: now); fatalError("Malformed CAPTCHA image was accepted") }
        catch PluginFailure.unsupportedResponse {}
        let image = await client.captchaChallenge
        require(image == nil, "Malformed CAPTCHA was published")
    }

    let delayed = FixtureTransport([company, challengeLogin, captcha], holdPath: captcha.path)
    let cancelledClient = DaouOfficeAPIClient(configuration: config, secrets: FixtureSecrets(password: "fixture-secret"), transport: delayed)
    let pending = Task { try await cancelledClient.refresh(now: now) }
    while !(await delayed.isHeld()) { await Task.yield() }
    cancelledClient.cancel()
    await delayed.releaseHeld()
    do { _ = try await pending.value; fatalError("Cancelled CAPTCHA response was published") }
    catch is CancellationError {}
    let cancelledChallenge = await cancelledClient.captchaChallenge, cancelledDiagnostic = await cancelledClient.diagnostic
    let cancelledRequired = await cancelledClient.requiresCaptcha
    let cancelledLoginDiagnostic = await cancelledClient.lastLoginDiagnostic
    require(cancelledChallenge == nil && cancelledDiagnostic == nil && !cancelledRequired, "Cancelled CAPTCHA retained state")
    require(cancelledLoginDiagnostic == nil, "Cancelled CAPTCHA kept its login diagnostic")
    do { _ = try await cancelledClient.refresh(now: now); fatalError("Cancelled client resumed login") }
    catch is CancellationError {}
    print("PASS CAPTCHA: human continuation, same transport, new image IDs, bounded PNG, no retry and cancellation")
}
