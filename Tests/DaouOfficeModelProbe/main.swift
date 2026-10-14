import AppKit
import SwiftUI
import Foundation
import AppPluginCore
import DaouOfficePlugin

func require(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }

final class MemorySecrets: PluginSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func load(for key: String) throws -> String? { lock.withLock { values[key] } }
    func save(_ password: String, for key: String) throws { lock.withLock { values[key] = password } }
    func remove(for key: String) throws { lock.withLock { values[key] = nil } }
}

struct UnreadableSecrets: PluginSecretStore {
    func load(for key: String) throws -> String? { throw PluginFailure.credentials }
    func save(_ password: String, for key: String) throws { fatalError("Unreadable fixture must not save credentials") }
    func remove(for key: String) throws { fatalError("Unreadable fixture must not remove credentials") }
}

actor PausedTransport: DaouOfficeTransport {
    var began = false
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        began = true
        try await Task.sleep(for: .seconds(30))
        fatalError("Cancelled request was not stopped")
    }
    nonisolated func cancel() {}
}

struct ModelAPIStep: Sendable {
    let path: String
    var method = "GET"
    let json: String
    var status = 200
    var contentType = "application/json"
    var held = false
}

/// One fake transport represents one cookie session. Held responses deliberately finish after
/// cancellation so the model must reject stale CAPTCHA and login results itself.
actor CaptchaModelTransport: DaouOfficeTransport {
    private var steps: [ModelAPIStep]
    private let previewCaptcha: ModelAPIStep?
    private var requests: [URLRequest] = []
    private var heldResponse: CheckedContinuation<Void, Never>?
    init(_ steps: [ModelAPIStep], previewCaptcha: ModelAPIStep? = nil) {
        self.steps = steps; self.previewCaptcha = previewCaptcha
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step: ModelAPIStep
        if !steps.isEmpty { step = steps.removeFirst() }
        else if let previewCaptcha {
            // UI previews remain fixtures even if someone uses the visible controls.
            switch request.url?.path {
            case bootstrapStep.path: step = bootstrapStep
            case companyStep.path: step = companyStep
            case captchaLoginStep.path: step = captchaLoginStep
            case previewCaptcha.path: step = previewCaptcha
            default: fatalError("Unexpected fixture preview route")
            }
        } else { fatalError("Unexpected CAPTCHA model request") }
        require(request.url?.path == step.path, "Wrong CAPTCHA model route")
        require(request.httpMethod == step.method, "Wrong CAPTCHA model request method")
        requests.append(request)
        if step.held {
            await withCheckedContinuation { heldResponse = $0 }
        }
        return (Data(step.json.utf8), HTTPURLResponse(url: request.url!, statusCode: step.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": step.contentType])!)
    }
    nonisolated func cancel() {}
    var isHeld: Bool { heldResponse != nil }
    func release() { heldResponse?.resume(); heldResponse = nil }
    func captured() -> [URLRequest] { requests }
    func remaining() -> Int { steps.count }
}

final class ClientCreations: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private let fixturePNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="
private let bootstrapStep = ModelAPIStep(path: "/login", json: "<html><body>Fixture login page</body></html>", contentType: "text/html")
private let companyStep = ModelAPIStep(path: "/api/portal/public/auth/company",
    json: #"{"data":{"companyList":[{"companyId":"1476755976291233792"}]}}"#)
private let captchaLoginStep = ModelAPIStep(path: "/api/portal/public/auth/login", method: "POST",
    json: #"{"code":"PORTAL-0003"}"#, status: 400)
private let captchaStep = ModelAPIStep(path: "/api/portal/public/auth/captcha", method: "PUT",
    json: "{\"data\":{\"captchaImage\":\"" + fixturePNG + "\"}}")
private let successfulLoginStep = ModelAPIStep(path: "/api/portal/public/auth/login", method: "POST",
    json: #"{"data":{}}"#)

@MainActor
private func demoCaptchaStep() -> ModelAPIStep {
    // A synthetic test image: this never reads, interprets or solves a real CAPTCHA.
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 260, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Could not make the DEMO fixture") }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 260, height: 80)).fill()
    let text = "DEMO" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 42, weight: .semibold), .foregroundColor: NSColor.black
    ]
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (260 - size.width) / 2, y: (80 - size.height) / 2), withAttributes: attributes)
    guard let image = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode the DEMO fixture") }
    return ModelAPIStep(path: "/api/portal/public/auth/captcha", method: "PUT",
        json: "{\"data\":{\"captchaImage\":\"" + image.base64EncodedString() + "\"}}")
}

private func successfulReadSteps() -> [ModelAPIStep] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    let year = calendar.component(.year, from: Date())
    return [
        ModelAPIStep(path: "/api/leave/normal/my/annual/summary",
            json: #"{"data":{"totalDays":7,"usedDays":4.5,"formattedRemain":"2.5d (20h 0m)"}}"#),
        ModelAPIStep(path: "/api/leave/normal/my/upcoming", json: #"{"data":{"elements":[]}}"#),
        ModelAPIStep(path: "/api/leave/normal/my/past/\(year)", json: #"{"data":{"elements":[]}}"#),
        ModelAPIStep(path: "/gw/api/user/session", json: #"{"code":"200","data":{"id":"900"}}"#),
        ModelAPIStep(path: "/gw/api/calendar/user/900/calendar", json: #"{"code":"200","data":[{"id":"123"}]}"#),
        ModelAPIStep(path: "/gw/api/calendar/event", json: #"{"code":"200","data":[]}"#)
    ]
}

@MainActor
private func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        require(Date() < deadline, message)
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func waitUntilHeld(_ transport: CaptchaModelTransport) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !(await transport.isHeld) {
        require(Date() < deadline, "Expected CAPTCHA request did not reach the held transport")
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func captchaModel(folder: URL, transport: CaptchaModelTransport,
                          creations: ClientCreations = ClientCreations(),
                          secrets: MemorySecrets = MemorySecrets(),
                          initialPassword: String = "fixture-secret") -> DaouOfficePluginModel {
    let store = DaouOfficeConfigurationStore(url: folder.appendingPathComponent(UUID().uuidString + "/config.json"))
    let model = DaouOfficePluginModel(store: store, secrets: secrets, makeClient: {
        creations.increment()
        return DaouOfficeAPIClient(configuration: $0, secrets: $1, transport: transport)
    })
    model.start()
    model.setEnableRequested(true)
    model.address = "https://example.daouoffice.com"
    model.loginID = "employee"
    model.password = initialPassword
    model.saveAndRefresh()
    return model
}

@MainActor
private func checkCaptchaModelLifecycle(folder: URL) async throws {
    let creations = ClientCreations()
    let transport = CaptchaModelTransport([bootstrapStep, companyStep, captchaLoginStep, captchaStep, successfulLoginStep] + successfulReadSteps())
    let model = captchaModel(folder: folder, transport: transport, creations: creations)
    defer { model.stop() }
    try await waitUntil("CAPTCHA challenge was not presented") { model.captchaChallenge != nil && !model.isRunning }
    require(model.enabled && model.nextRunAt == nil && model.snapshot == nil, "CAPTCHA waiting state schedules work or publishes data")
    require(model.password.isEmpty && model.captchaAnswer.isEmpty, "Draft secret was kept while waiting for CAPTCHA")
    require(!model.canSubmitCaptcha && model.canReloadCaptcha, "CAPTCHA actions do not reflect empty human input")
    model.refresh()
    model.refresh(reconnect: true)
    model.submitCaptcha()
    for _ in 0..<10 { await Task.yield() }
    let waitingRequests = await transport.captured()
    require(waitingRequests.count == 4 && creations.value == 1, "Waiting CAPTCHA silently retries or replaces its cookie session")
    require(model.captchaChallenge != nil && !model.isRunning, "Empty answer discarded the challenge")
    model.captchaAnswer = "HUMAN-FIXTURE"
    require(model.canSubmitCaptcha, "Human answer did not enable CAPTCHA submission")
    model.submitCaptcha()
    try await waitUntil("CAPTCHA login did not publish the snapshot") { model.snapshot != nil && !model.isRunning }
    require(model.failure == nil && model.captchaChallenge == nil && model.captchaAnswer.isEmpty, "Successful CAPTCHA leaves stale authentication UI")
    require(model.nextRunAt != nil && model.api.snapshot(for: "daouoffice") == model.snapshot, "CAPTCHA success did not resume the internal plugin API")
    let submitted = await transport.captured(), remaining = await transport.remaining()
    require(remaining == 0 && creations.value == 1, "CAPTCHA success did not reuse its configured client")
    let body = try JSONSerialization.jsonObject(with: submitted[4].httpBody!) as! [String: Any]
    require(body["captcha"] as? String == "HUMAN-FIXTURE", "Human answer was not sent to login")
    require(body["password"] as? String == "fixture-secret", "CAPTCHA submission lost the saved credential")
    print("PASS CAPTCHA model: waiting, blocked polling, empty answer, same-session submit and API publication")
}

@MainActor
private func checkCaptchaModelReloadAndFailure(folder: URL) async throws {
    let rejectedLogin = ModelAPIStep(path: "/api/portal/public/auth/login", method: "POST",
        json: #"{"code":"PORTAL-0012","data":{"needCaptchaRequest":true}}"#, status: 400)
    let transport = CaptchaModelTransport([bootstrapStep, companyStep, captchaLoginStep, captchaStep,
        captchaStep, rejectedLogin, captchaStep, captchaStep])
    let model = captchaModel(folder: folder, transport: transport)
    defer { model.stop() }
    try await waitUntil("Initial CAPTCHA was not available") { model.captchaChallenge != nil && !model.isRunning }
    require(model.lastLoginDiagnostic?.path == captchaLoginStep.path && model.lastLoginDiagnostic?.status == 400 &&
            model.lastLoginDiagnostic?.code == "PORTAL-0003", "CAPTCHA image response replaced the initial login diagnostic")
    let firstChallenge = model.captchaChallenge!.id
    model.captchaAnswer = "OLD-ANSWER"
    model.reloadCaptcha()
    try await waitUntil("CAPTCHA reload did not finish") { !model.isRunning }
    let reloaded = await transport.captured()
    require(reloaded.count == 5 && reloaded[4].url?.path == captchaStep.path, "Image reload attempted another credential login")
    require(model.captchaChallenge != nil && model.captchaAnswer.isEmpty && model.nextRunAt == nil, "Reload preserved an answer to the previous image")
    require(model.captchaChallenge?.id != firstChallenge, "Reload retained the previous challenge identity")
    require(model.lastLoginDiagnostic?.code == "PORTAL-0003", "Image reload erased the last login result")
    let reloadedChallenge = model.captchaChallenge!.id
    model.captchaAnswer = "WRONG-FIXTURE"
    model.submitCaptcha()
    try await waitUntil("Rejected human answer did not stop") { !model.isRunning }
    let failed = await transport.captured()
    require(failed.filter { $0.httpMethod == "POST" }.count == 2, "Rejected human answer retried credentials automatically")
    require(model.snapshot == nil && model.nextRunAt == nil && model.captchaAnswer.isEmpty, "Rejected answer published data, persisted input or scheduled polling")
    require(model.captchaChallenge != nil, "Rejected answer lost the manual authentication path")
    require(model.captchaChallenge?.id != reloadedChallenge, "Rejected answer retained an obsolete image identity")
    require(model.lastLoginDiagnostic?.path == captchaLoginStep.path && model.lastLoginDiagnostic?.status == 400 &&
            model.lastLoginDiagnostic?.code == "PORTAL-0012" && model.lastLoginDiagnostic?.captchaRefreshRequired == true,
        "Refreshed CAPTCHA PNG hid the rejected login code or refresh-required flag")
    require(model.diagnostic?.path == captchaStep.path && model.diagnostic?.status == 200,
        "The latest image response is not kept separate from the last login result")
    model.refresh()
    for _ in 0..<10 { await Task.yield() }
    let afterRefresh = await transport.captured()
    require(afterRefresh.count == failed.count, "Ordinary refresh bypassed a rejected CAPTCHA answer")
    model.reloadCaptcha()
    try await waitUntil("Image reload after rejection did not finish") { !model.isRunning }
    require(model.lastLoginDiagnostic?.code == "PORTAL-0012" && model.lastLoginDiagnostic?.captchaRefreshRequired == true,
        "Explicit image reload erased the last rejected login metadata")
    let afterImageReload = await transport.captured()
    require(afterImageReload.count == failed.count + 1 && afterImageReload.filter { $0.httpMethod == "POST" }.count == 2,
        "Reloading a rejected challenge retried a password login")
    print("PASS CAPTCHA model: image reload, rejected answer and no automatic credential retry")
}

@MainActor
private func checkCaptchaPasswordContext(folder: URL) async throws {
    let secrets = MemorySecrets()
    let initialPassword = "fixture/original-context"
    let transport = CaptchaModelTransport([bootstrapStep, companyStep, captchaLoginStep, captchaStep,
        successfulLoginStep] + successfulReadSteps())
    let model = captchaModel(folder: folder, transport: transport, secrets: secrets, initialPassword: initialPassword)
    defer { model.stop() }
    try await waitUntil("Password-context fixture has no CAPTCHA") { model.captchaChallenge != nil && !model.isRunning }
    let config = try DaouOfficeConfiguration(enabled: true, address: model.address, loginID: model.loginID)
    // Simulate a separate writer changing the fake credential store while this challenge is open.
    try secrets.save("external-replacement-fixture", for: config.credentialKey)
    let changedPassword = try secrets.load(for: config.credentialKey)
    require(changedPassword == "external-replacement-fixture", "The fake store was not changed")
    model.captchaAnswer = "HUMAN-FIXTURE"
    model.submitCaptcha()
    try await waitUntil("Password-context submission did not finish") { model.snapshot != nil && !model.isRunning }
    let requests = await transport.captured()
    let logins = requests.filter { $0.url?.path == captchaLoginStep.path }
    require(logins.count == 2, "Password-context submission made an extra login")
    let first = try JSONSerialization.jsonObject(with: logins[0].httpBody!) as! [String: Any]
    let submitted = try JSONSerialization.jsonObject(with: logins[1].httpBody!) as! [String: Any]
    require(first["password"] as? String == initialPassword && submitted["password"] as? String == initialPassword,
        "Human CAPTCHA submission used a credential changed after its initial login")
    require(submitted["captcha"] as? String == "HUMAN-FIXTURE", "Password-context submission lost the human answer")
    for login in logins {
        let bytes = String(decoding: login.httpBody!, as: UTF8.self)
        require(bytes.contains(initialPassword) && !bytes.contains("fixture\\/original-context"),
            "Login JSON escaped a password slash differently from the web form")
    }
    print("PASS CAPTCHA model: initial credential context survives external fake-store changes and preserves JSON slashes")
}

@MainActor
private func checkCaptchaLoginDiagnosticReset(folder: URL) async throws {
    for action in ["edit", "disable"] {
        let transport = CaptchaModelTransport([bootstrapStep, companyStep, captchaLoginStep, captchaStep])
        let model = captchaModel(folder: folder, transport: transport)
        try await waitUntil("Diagnostic-reset fixture has no CAPTCHA") { model.captchaChallenge != nil && !model.isRunning }
        require(model.lastLoginDiagnostic?.code == "PORTAL-0003", "The waiting UI has no login diagnostic to clear")
        model.captchaAnswer = "UNSUBMITTED-FIXTURE"
        if action == "edit" { model.loginID = "another.employee" }
        else { model.setEnableRequested(false) }
        require(model.lastLoginDiagnostic == nil && model.captchaChallenge == nil && model.captchaAnswer.isEmpty,
            "Account edit or disable retained the waiting account's login diagnostic")
        for _ in 0..<10 { await Task.yield() }
        let requests = await transport.captured()
        require(requests.count == 4 && model.nextRunAt == nil, "Clearing a waiting diagnostic automatically attempted login")
        model.stop()
    }
    print("PASS CAPTCHA model: account edit and disable clear the visible last-login diagnostic without retrying")
}

@MainActor
private func checkCaptchaImageFailureRecovery(folder: URL) async throws {
    let failedImage = ModelAPIStep(path: captchaStep.path, method: "PUT",
        json: #"{"code":"INTERNAL_SERVER_ERROR"}"#, status: 503)
    let transport = CaptchaModelTransport([bootstrapStep, companyStep, captchaLoginStep, failedImage, captchaStep])
    let creations = ClientCreations()
    let model = captchaModel(folder: folder, transport: transport, creations: creations)
    defer { model.stop() }
    try await waitUntil("Failed CAPTCHA image did not stop") { !model.isRunning }
    require(model.captchaChallenge == nil && model.failure == .network && model.nextRunAt == nil,
        "Failed CAPTCHA image was treated as a fresh normal-login opportunity")
    model.refresh(reconnect: true)
    try await waitUntil("Explicit image retry did not provide a CAPTCHA") { model.captchaChallenge != nil && !model.isRunning }
    let requests = await transport.captured()
    require(requests.count == 5 && requests.last?.url?.path == captchaStep.path && creations.value == 1,
        "Retrying a failed CAPTCHA image replaced its session or resent credentials")
    require(requests.filter { $0.httpMethod == "POST" }.count == 1, "Image retry performed a second password login")
    print("PASS CAPTCHA model: failed image retry preserves the waiting session and never resends credentials")
}

@MainActor
private func checkCaptchaSavedConnectionReset(folder: URL) async throws {
    let transport = CaptchaModelTransport([bootstrapStep, companyStep, captchaLoginStep, captchaStep,
        bootstrapStep, companyStep, successfulLoginStep] + successfulReadSteps())
    let creations = ClientCreations()
    let model = captchaModel(folder: folder, transport: transport, creations: creations)
    defer { model.stop() }
    try await waitUntil("Save-reset fixture has no CAPTCHA") { model.captchaChallenge != nil && !model.isRunning }
    model.captchaAnswer = "UNSUBMITTED-FIXTURE"
    model.saveAndRefresh()
    require(model.captchaChallenge == nil && model.captchaAnswer.isEmpty && model.lastLoginDiagnostic == nil,
        "Explicit save retained the previous challenge, draft answer or login diagnostic")
    try await waitUntil("Explicit save did not reconnect") { model.snapshot != nil && !model.isRunning }
    let requests = await transport.captured()
    require(creations.value == 2, "Explicit save retained an old authentication client")
    let loginBody = try JSONSerialization.jsonObject(with: requests[6].httpBody!) as! [String: Any]
    require(loginBody["captcha"] as? String == "", "Explicit save submitted a previous challenge's unconfirmed answer")
    print("PASS CAPTCHA model: explicit save resets the challenge, answer and authentication client")
}

@MainActor
private func checkCaptchaCancelRecovery(folder: URL) async throws {
    let initial = CaptchaModelTransport([bootstrapStep, companyStep, captchaLoginStep, captchaStep])
    let renewed = CaptchaModelTransport([bootstrapStep, companyStep, captchaLoginStep, captchaStep,
        successfulLoginStep] + successfulReadSteps())
    let creations = ClientCreations(), secrets = MemorySecrets()
    let store = DaouOfficeConfigurationStore(url: folder.appendingPathComponent("cancel-recovery/config.json"))
    let model = DaouOfficePluginModel(store: store, secrets: secrets, makeClient: {
        creations.increment()
        return DaouOfficeAPIClient(configuration: $0, secrets: $1, transport: creations.value == 1 ? initial : renewed)
    })
    defer { model.stop() }
    model.start(); model.setEnableRequested(true)
    model.address = "https://example.daouoffice.com"; model.loginID = "employee"; model.password = "fixture-secret"
    model.saveAndRefresh()
    try await waitUntil("Cancel-recovery fixture has no CAPTCHA") { model.captchaChallenge != nil && !model.isRunning }
    let oldChallenge = model.captchaChallenge?.id
    let savedBytes = try Data(contentsOf: store.url)
    model.captchaAnswer = "UNSUBMITTED-FIXTURE"
    model.cancelCaptcha()
    for _ in 0..<10 { await Task.yield() }
    let beforeRetry = await initial.captured()
    require(beforeRetry.count == 4 && creations.value == 1 && model.enabled && model.canRefresh && model.nextRunAt == nil,
        "CAPTCHA cancellation automatically retried or disabled explicit recovery")
    require(model.captchaChallenge == nil && model.captchaAnswer.isEmpty && model.lastLoginDiagnostic == nil,
        "CAPTCHA cancellation retained the previous challenge or answer")
    model.refresh()
    try await waitUntil("Explicit refresh after CAPTCHA cancellation did not finish") { !model.isRunning }
    require(model.captchaChallenge != nil && model.captchaChallenge?.id != oldChallenge && model.failure == .interactionRequired && creations.value == 2,
        "Explicit refresh after CAPTCHA cancellation failed to create a new authentication session")
    let freshRequests = await renewed.captured()
    require(freshRequests.count == 4 && freshRequests.filter { $0.httpMethod == "POST" }.count == 1,
        "Explicit recovery did not perform exactly one new login and CAPTCHA fetch")
    let savedAfterCancel = try Data(contentsOf: store.url)
    let config = try DaouOfficeConfiguration(enabled: true, address: model.address, loginID: model.loginID)
    let savedPassword = try secrets.load(for: config.credentialKey)
    require(savedAfterCancel == savedBytes && savedPassword == "fixture-secret", "Recovery changed saved settings or credentials")
    model.captchaAnswer = "HUMAN-FIXTURE"; model.submitCaptcha()
    try await waitUntil("Recovered CAPTCHA did not publish the snapshot") { model.snapshot != nil && !model.isRunning }
    let finalRequests = await renewed.captured(), oldRequests = await initial.captured()
    require(oldRequests.count == 4 && finalRequests.count == 11 && creations.value == 2 && model.failure == nil &&
        model.api.snapshot(for: "daouoffice") == model.snapshot && model.nextRunAt != nil,
        "Recovered CAPTCHA session was replaced, reused the cancelled client or failed to resume polling")
    print("PASS CAPTCHA cancel recovery: explicit new session, fresh challenge, saved credentials, snapshot publication and no automatic login")
}

@MainActor
private func checkCaptchaModelCancellation(folder: URL) async throws {
    var pendingImage = captchaStep
    pendingImage.held = true
    let transport = CaptchaModelTransport([bootstrapStep, companyStep, captchaLoginStep, pendingImage])
    let model = captchaModel(folder: folder, transport: transport)
    try await waitUntilHeld(transport)
    model.setEnableRequested(false)
    await transport.release()
    for _ in 0..<20 { await Task.yield() }
    require(!model.enabled && !model.isRunning && model.captchaChallenge == nil && model.captchaAnswer.isEmpty,
        "Late image response revived disabled CAPTCHA UI")
    require(model.failure == nil && model.nextRunAt == nil && model.api.snapshot(for: "daouoffice") == nil,
        "Late image response changed disabled plugin state")
    require(model.lastLoginDiagnostic == nil, "Late image response revived a disabled account's login diagnostic")
    model.stop()

    for field in ["address", "loginID", "password", "disable", "cancel", "stop"] {
        var pendingLogin = successfulLoginStep
        pendingLogin.held = true
        let heldTransport = CaptchaModelTransport([bootstrapStep, companyStep, captchaLoginStep, captchaStep, pendingLogin])
        let heldModel = captchaModel(folder: folder, transport: heldTransport)
        try await waitUntil("Cancellation fixture has no CAPTCHA") { heldModel.captchaChallenge != nil && !heldModel.isRunning }
        require(heldModel.lastLoginDiagnostic?.code == "PORTAL-0003", "Cancellation fixture is missing its previous login result")
        heldModel.captchaAnswer = "HUMAN-FIXTURE"
        heldModel.submitCaptcha()
        try await waitUntilHeld(heldTransport)
        switch field {
        case "address": heldModel.address = "https://another.daouoffice.com"
        case "loginID": heldModel.loginID = "another.employee"
        case "password": heldModel.password = "replacement-fixture"
        case "disable": heldModel.setEnableRequested(false)
        case "cancel": heldModel.cancelCaptcha()
        default: heldModel.stop()
        }
        require(!heldModel.isRunning && heldModel.captchaChallenge == nil && heldModel.captchaAnswer.isEmpty && heldModel.lastLoginDiagnostic == nil,
            "Editing or stopping left a CAPTCHA bound to the old account")
        await heldTransport.release()
        for _ in 0..<20 { await Task.yield() }
        let requests = await heldTransport.captured()
        require(requests.count == 5 && heldModel.snapshot == nil && heldModel.failure == nil && heldModel.nextRunAt == nil && heldModel.lastLoginDiagnostic == nil,
            "Late CAPTCHA login resumed data fetch or changed the replacement draft")
        require(heldModel.api.snapshot(for: "daouoffice") == nil, "Cancelled CAPTCHA session published data through the internal API")
        heldModel.stop()
    }
    print("PASS CAPTCHA model: stale image/login cancellation, account edits, disable and stop")
}

@MainActor
private func checkSavedPasswordPresence(folder: URL) async throws {
    let config = try DaouOfficeConfiguration(enabled: false, address: "https://example.daouoffice.com", loginID: "employee")
    let missingValues: [String?] = [nil, ""]
    for savedPassword in missingValues {
        let store = DaouOfficeConfigurationStore(url: folder.appendingPathComponent(UUID().uuidString + "/config.json"))
        try store.save(config)
        let secrets = MemorySecrets()
        if let savedPassword { try secrets.save(savedPassword, for: config.credentialKey) }
        let transport = CaptchaModelTransport([bootstrapStep, companyStep, successfulLoginStep] + successfulReadSteps())
        let creations = ClientCreations()
        let model = DaouOfficePluginModel(store: store, secrets: secrets, makeClient: {
            creations.increment()
            return DaouOfficeAPIClient(configuration: $0, secrets: $1, transport: transport)
        })
        require(!model.hasSavedPassword && !model.canUseSavedPassword && !model.enabled && !model.enableRequested,
            "Existing disabled configuration claims a missing or empty saved password")
        model.start()
        model.setEnableRequested(true)
        require(!model.canSave, "An empty draft can save a connection with no stored password")
        model.saveAndRefresh()
        let blankRequests = await transport.captured()
        require(blankRequests.isEmpty && creations.value == 0 && !model.isRunning && model.failure == .missingCredentials,
            "Enabling or saving with no password initiated authentication")
        model.password = "new-fixture-secret"
        require(model.canSave, "Entering a new password did not enable saving")
        model.saveAndRefresh()
        try await waitUntil("New password did not save and fetch the fixture data") { model.snapshot != nil && !model.isRunning }
        require(model.hasSavedPassword && model.canUseSavedPassword && model.password.isEmpty && model.failure == nil,
            "Successful new-password save did not restore the stored-password state")
        let stored = try secrets.load(for: config.credentialKey)
        let requests = await transport.captured()
        let login = requests.first { $0.url?.path == successfulLoginStep.path }!
        let body = try JSONSerialization.jsonObject(with: login.httpBody!) as! [String: Any]
        require(stored == "new-fixture-secret" && body["password"] as? String == stored && creations.value == 1,
            "New password was not saved and used for the single explicit login")
        model.stop()
    }
    let unreadableStore = DaouOfficeConfigurationStore(url: folder.appendingPathComponent(UUID().uuidString + "/config.json"))
    try unreadableStore.save(config)
    let unreadable = DaouOfficePluginModel(store: unreadableStore, secrets: UnreadableSecrets())
    require(!unreadable.hasSavedPassword && !unreadable.canUseSavedPassword && unreadable.failure == .credentials,
        "Saved-password read failure was hidden or mistaken for a configuration error")
    unreadable.stop()
    print("PASS plugin model: missing/empty saved passwords, explicit replacement and credential-read failures")
}

@MainActor
func checks() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HappyLulu-plugin-model-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = DaouOfficeConfigurationStore(url: folder.appendingPathComponent("config.json"))
    let secrets = MemorySecrets()
    let paused = PausedTransport()
    let model = DaouOfficePluginModel(store: store, secrets: secrets, makeClient: {
        DaouOfficeAPIClient(configuration: $0, secrets: $1, transport: paused)
    })
    model.start()
    require(!model.enabled && !model.isRunning, "Unconfigured plugin initiated background work")
    model.setEnableRequested(true)
    model.address = "https://example.daouoffice.com"; model.loginID = "employee"; model.password = "fixture-secret"
    model.saveAndRefresh()
    require(model.enabled && model.isRunning && model.password.isEmpty, "Save did not begin a background fetch and clear draft secret")
    while !(await paused.began) { await Task.yield() }
    let config = try store.load()!
    let password = try secrets.load(for: config.credentialKey)
    require(password == "fixture-secret", "Credential was not scoped")
    model.setEnableRequested(false)
    require(!model.enabled && !model.isRunning && model.snapshot == nil, "Disabling did not clear work/results")
    require(model.api.snapshot(for: "daouoffice") == nil, "Internal API exposes disabled data")
    let saved = try store.load()!
    require(!saved.enabled, "Disabled preference did not persist")
    for _ in 0..<10 { await Task.yield() }
    require(model.failure == nil && model.nextRunAt == nil, "Cancelled fetch overwrote disabled state")
    let reopened = DaouOfficePluginModel(store: store, secrets: secrets)
    require(!reopened.enabled && reopened.address == config.baseURL.absoluteString, "Disabled configuration did not restore")
    require(reopened.canUseSavedPassword, "Matching account lost saved password option")
    reopened.loginID = "another.employee"
    require(!reopened.canUseSavedPassword, "Password reused across identities")
    model.stop(); reopened.stop()

    let blockedFile = folder.appendingPathComponent("not-a-directory")
    try Data("fixture".utf8).write(to: blockedFile)
    let failedStore = DaouOfficeConfigurationStore(url: blockedFile.appendingPathComponent("config.json"))
    let failed = DaouOfficePluginModel(store: failedStore, secrets: secrets)
    failed.setEnableRequested(true); failed.address = config.baseURL.absoluteString
    failed.loginID = config.loginID; failed.password = "replacement-secret"
    failed.saveAndRefresh()
    require(!failed.enabled && failed.failure == .configuration, "Failed metadata save started networking")
    let preserved = try secrets.load(for: config.credentialKey)
    require(preserved == "fixture-secret", "Failed save did not roll back password")
    print("PASS plugin model: opt-in, save/fetch, credential scope, restart, cancellation and transactional save")
    try await checkSavedPasswordPresence(folder: folder)
    try await checkCaptchaModelLifecycle(folder: folder)
    try await checkCaptchaModelReloadAndFailure(folder: folder)
    try await checkCaptchaPasswordContext(folder: folder)
    try await checkCaptchaLoginDiagnosticReset(folder: folder)
    try await checkCaptchaImageFailureRecovery(folder: folder)
    try await checkCaptchaSavedConnectionReset(folder: folder)
    try await checkCaptchaCancelRecovery(folder: folder)
    try await checkCaptchaModelCancellation(folder: folder)
}

if CommandLine.arguments.contains("--show-ui") || CommandLine.arguments.contains("--show-captcha-ui") {
    // Isolated screen: no real company session, settings or Keychain in either preview mode.
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let showingCaptcha = CommandLine.arguments.contains("--show-captcha-ui")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HappyLulu-plugin-ui-" + UUID().uuidString)
    let transport = CaptchaModelTransport([], previewCaptcha: demoCaptchaStep())
    let model = DaouOfficePluginModel(store: DaouOfficeConfigurationStore(url: folder.appendingPathComponent("config.json")),
        secrets: MemorySecrets(), makeClient: { DaouOfficeAPIClient(configuration: $0, secrets: $1, transport: transport) })
    model.setEnableRequested(true)
    model.address = "https://company.daouoffice.com/"
    if showingCaptcha {
        model.loginID = "demo.employee"
        model.password = "fixture-secret"
        model.saveAndRefresh()
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 660),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = showingCaptcha ? "HappyLulu · CAPTCHA 미리보기" : "HappyLulu · 플러그인 미리보기"
    window.contentViewController = NSHostingController(rootView: ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("플러그인", "Plugins")).font(.title.bold())
            Text(L("다우오피스 휴가와 일정을 연결합니다.", "Connect Daouoffice leave and events.")).foregroundStyle(.secondary)
            Text(L("테스트 데이터 미리보기입니다. 실제 회사 계정에는 접속하지 않습니다.", "Test data preview. No real company account is contacted."))
                .font(.caption).foregroundStyle(.secondary)
            DaouOfficePluginSettingsView(model: model)
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }.tint(Color(red: 0.16, green: 0.48, blue: 0.42)))
    window.center(); window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    application.run()
} else {
    Task { @MainActor in
        do { try await checks(); exit(0) }
        catch { print("FAIL plugin model: \(error)"); exit(1) }
    }
    dispatchMain()
}
