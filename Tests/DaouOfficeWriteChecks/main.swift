import Foundation
import DaouOfficeWritePlugin

func require(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

func expectFailure(_ expected: ReservationFailure, _ body: () async throws -> Void) async {
    do {
        try await body()
        fatalError("Expected failure: \(expected)")
    } catch let failure as ReservationFailure {
        require(failure == expected, "Unexpected failure: \(failure)")
    } catch {
        fatalError("Unexpected error type")
    }
}

final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_900_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

enum FixtureError: Error { case timeout }

actor AvailabilityFixture: ReservationAvailabilityTransport {
    var answers: [ReservationAvailability]
    private var reads = 0
    var shouldThrow = false
    var pause = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ answers: [ReservationAvailability] = [.available]) { self.answers = answers }
    func availability(for request: ReservationRequest) async throws -> ReservationAvailability {
        reads += 1
        if pause { await withCheckedContinuation { continuation = $0 } }
        if shouldThrow { throw FixtureError.timeout }
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
    func count() -> Int { reads }
    func setThrowing() { shouldThrow = true }
    func setPaused() { pause = true }
    func waiting() -> Bool { continuation != nil }
    func resume() { pause = false; continuation?.resume(); continuation = nil }
}

actor CommandFixture: ReservationCommandTransport {
    enum Behavior: Sendable { case success, timeout, cancellation, blankID, uncertain, notSent, paused }
    private let behavior: Behavior
    private var requests: [ReservationRequest] = []
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ behavior: Behavior = .success) { self.behavior = behavior }
    func create(_ request: ReservationRequest, requestID: UUID) async throws -> ReservationResult {
        requests.append(request)
        switch behavior {
        case .success: return .confirmed(reservationID: "synthetic-booking")
        case .timeout: throw FixtureError.timeout
        case .cancellation: throw CancellationError()
        case .blankID: return .confirmed(reservationID: "  ")
        case .uncertain: return .uncertain
        case .notSent: return .notSent(.contractUnverified)
        case .paused:
            await withCheckedContinuation { continuation = $0 }
            return .confirmed(reservationID: "synthetic-booking")
        }
    }
    func count() -> Int { requests.count }
    func lastRequest() -> ReservationRequest? { requests.last }
    func waiting() -> Bool { continuation != nil }
    func resume() { continuation?.resume(); continuation = nil }
}

func request(_ clock: FixtureClock, title: String = "가상 회의", account: String = "synthetic-account") -> ReservationRequest {
    ReservationRequest(connectionID: "synthetic-connection", accountID: account, resourceID: "synthetic-room",
                       title: title, start: clock.now().addingTimeInterval(3600),
                       end: clock.now().addingTimeInterval(5400), timeZoneID: "Asia/Seoul")
}

func simulation(_ clock: FixtureClock, _ availability: AvailabilityFixture, _ commands: CommandFixture) -> DaouOfficeWritePlugin {
    DaouOfficeWritePlugin(mode: .simulation, availability: availability, commands: commands, now: clock.now)
}

func checkDisabledAndUnsupported() async throws {
    let clock = FixtureClock(), availability = AvailabilityFixture(), commands = CommandFixture()
    let disabled = DaouOfficeWritePlugin(availability: availability, commands: commands, now: clock.now)
    await expectFailure(.disabled) { _ = try await disabled.prepare(request(clock)) }
    await expectFailure(.disabled) { _ = try await disabled.submit(draftID: UUID(), confirmed: true) }
    require(await availability.count() == 0, "Disabled plugin queried transport")
    require(await commands.count() == 0, "Disabled plugin sent command")
    let stub = DaouOfficeWritePlugin(mode: .simulation, now: clock.now)
    await expectFailure(.contractUnverified) { _ = try await stub.prepare(request(clock)) }
    let transport = UnimplementedReservationTransport()
    let response = try await transport.create(request(clock), requestID: UUID())
    require(response == .notSent(.contractUnverified), "Unverified command did not fail closed")
    let plugin = simulation(clock, availability, commands)
    for operation in [ReservationOperation.change, .cancel] {
        await expectFailure(.unsupportedOperation) { _ = try await plugin.prepare(request(clock), operation: operation) }
    }
    require(await availability.count() == 0, "Unsupported operation made a read")
    print("PASS disabled, unverified transport, unsupported change/cancel: no commands")
}

func checkValidation() async throws {
    let clock = FixtureClock(), availability = AvailabilityFixture(), commands = CommandFixture()
    let plugin = simulation(clock, availability, commands), valid = request(clock)
    let invalid = [
        ReservationRequest(connectionID: " ", accountID: valid.accountID, resourceID: valid.resourceID, title: valid.title, start: valid.start, end: valid.end, timeZoneID: valid.timeZoneID),
        ReservationRequest(connectionID: valid.connectionID, accountID: "", resourceID: valid.resourceID, title: valid.title, start: valid.start, end: valid.end, timeZoneID: valid.timeZoneID),
        ReservationRequest(connectionID: valid.connectionID, accountID: valid.accountID, resourceID: "", title: valid.title, start: valid.start, end: valid.end, timeZoneID: valid.timeZoneID),
        ReservationRequest(connectionID: valid.connectionID, accountID: valid.accountID, resourceID: valid.resourceID, title: "\n ", start: valid.start, end: valid.end, timeZoneID: valid.timeZoneID),
        ReservationRequest(connectionID: valid.connectionID, accountID: valid.accountID, resourceID: valid.resourceID, title: valid.title, start: valid.start, end: valid.end, timeZoneID: "Invalid/Zone"),
        ReservationRequest(connectionID: valid.connectionID, accountID: valid.accountID, resourceID: valid.resourceID, title: valid.title, start: clock.now(), end: valid.end, timeZoneID: valid.timeZoneID),
        ReservationRequest(connectionID: valid.connectionID, accountID: valid.accountID, resourceID: valid.resourceID, title: valid.title, start: valid.end, end: valid.start, timeZoneID: valid.timeZoneID),
        ReservationRequest(connectionID: valid.connectionID, accountID: valid.accountID, resourceID: valid.resourceID, title: valid.title, start: valid.start, end: valid.start, timeZoneID: valid.timeZoneID),
        ReservationRequest(connectionID: valid.connectionID, accountID: valid.accountID, resourceID: valid.resourceID, title: valid.title, start: Date(timeIntervalSince1970: .nan), end: valid.end, timeZoneID: valid.timeZoneID),
        ReservationRequest(connectionID: valid.connectionID, accountID: valid.accountID, resourceID: valid.resourceID, title: valid.title, start: valid.start, end: Date(timeIntervalSince1970: .infinity), timeZoneID: valid.timeZoneID)
    ]
    for item in invalid { await expectFailure(.invalidRequest) { _ = try await plugin.prepare(item) } }
    require(await availability.count() == 0, "Invalid request reached availability")
    require(await commands.count() == 0, "Invalid request reached command")
    print("PASS validation: identifiers, title, timezone, past/reversed/empty/nonfinite interval")
}

func checkDraftAndConfirmation() async throws {
    let clock = FixtureClock(), availability = AvailabilityFixture(), commands = CommandFixture()
    let plugin = simulation(clock, availability, commands), input = request(clock)
    let draft = try await plugin.prepare(input)
    require(draft.request == input && draft.expiresAt == clock.now().addingTimeInterval(120), "Draft lost confirmed fields or expiry")
    require(await commands.count() == 0, "Prepare wrote a reservation")
    await expectFailure(.confirmationRequired) { _ = try await plugin.submit(draftID: draft.id, confirmed: false) }
    await expectFailure(.draftNotFound) { _ = try await plugin.submit(draftID: UUID(), confirmed: true) }
    let other = simulation(clock, availability, commands)
    await expectFailure(.draftNotFound) { _ = try await other.submit(draftID: draft.id, confirmed: true) }
    let first = try await plugin.submit(draftID: draft.id, confirmed: true)
    require(first == .confirmed(reservationID: "synthetic-booking"), "Confirmed simulation failed")
    let repeatResult = try await plugin.submit(draftID: draft.id, confirmed: true)
    require(repeatResult == first, "Same draft did not return recorded result")
    require(await availability.count() == 2, "Submit did not recheck availability or repeated it")
    require(await commands.count() == 1, "Repeated draft resent command")
    require(await commands.lastRequest() == input, "Sent request differed from confirmation")
    let duplicate = try await plugin.prepare(request(clock, title: "다른 제목"))
    await expectFailure(.duplicateReservation) { _ = try await plugin.submit(draftID: duplicate.id, confirmed: true) }
    let sameInstant = ReservationRequest(connectionID: input.connectionID, accountID: input.accountID,
                                        resourceID: input.resourceID, title: input.title, start: input.start,
                                        end: input.end, timeZoneID: "UTC")
    let differentDisplayZone = try await plugin.prepare(sameInstant)
    await expectFailure(.duplicateReservation) { _ = try await plugin.submit(draftID: differentDisplayZone.id, confirmed: true) }
    require(await commands.count() == 1, "Title change bypassed duplicate protection")
    let differentAccount = try await plugin.prepare(request(clock, account: "synthetic-other-account"))
    _ = try await plugin.submit(draftID: differentAccount.id, confirmed: true)
    require(await commands.count() == 2, "Independent account incorrectly shared command result")
    print("PASS immutable confirmation, foreign ID, recheck, replay and account-scoped deduplication")
}

func checkExpiryAndAvailability() async throws {
    let boundaryClock = FixtureClock(), boundaryAvailability = AvailabilityFixture(), boundaryCommands = CommandFixture()
    let boundary = simulation(boundaryClock, boundaryAvailability, boundaryCommands)
    let boundaryDraft = try await boundary.prepare(request(boundaryClock))
    boundaryClock.advance(119)
    require(try await boundary.submit(draftID: boundaryDraft.id, confirmed: true) == .confirmed(reservationID: "synthetic-booking"),
            "Unexpired draft was rejected")
    for elapsed in [120.0, 121.0] {
        let clock = FixtureClock(), availability = AvailabilityFixture(), commands = CommandFixture()
        let plugin = simulation(clock, availability, commands), draft = try await plugin.prepare(request(clock))
        clock.advance(elapsed)
        await expectFailure(.draftExpired) { _ = try await plugin.submit(draftID: draft.id, confirmed: true) }
        require(await commands.count() == 0, "Expired draft sent command")
    }
    for state in [ReservationAvailability.unavailable, .unknown] {
        let clock = FixtureClock(), availability = AvailabilityFixture([state]), commands = CommandFixture()
        let plugin = simulation(clock, availability, commands)
        let expected: ReservationFailure = state == .unavailable ? .unavailable : .availabilityUnknown
        await expectFailure(expected) { _ = try await plugin.prepare(request(clock)) }
        let changed = AvailabilityFixture([.available, state]), rechecked = simulation(clock, changed, commands)
        let draft = try await rechecked.prepare(request(clock))
        await expectFailure(expected) { _ = try await rechecked.submit(draftID: draft.id, confirmed: true) }
        require(await commands.count() == 0, "Unavailable or unknown result sent command")
    }
    let clock = FixtureClock(), availability = AvailabilityFixture(), commands = CommandFixture()
    let plugin = simulation(clock, availability, commands), draft = try await plugin.prepare(request(clock))
    await availability.setThrowing()
    await expectFailure(.availabilityFailed) { _ = try await plugin.submit(draftID: draft.id, confirmed: true) }
    require(await commands.count() == 0, "Failed availability sent command")
    print("PASS expiry boundary, conflict/unknown/error before dispatch")
}

func checkUncertainResults() async throws {
    for behavior in [CommandFixture.Behavior.timeout, .cancellation, .blankID, .uncertain] {
        let clock = FixtureClock(), availability = AvailabilityFixture(), commands = CommandFixture(behavior)
        let plugin = simulation(clock, availability, commands), input = request(clock)
        let draft = try await plugin.prepare(input)
        require(try await plugin.submit(draftID: draft.id, confirmed: true) == .uncertain, "Ambiguous command reported success/failure")
        require(try await plugin.submit(draftID: draft.id, confirmed: true) == .uncertain, "Uncertain command replay changed result")
        let duplicate = try await plugin.prepare(input)
        await expectFailure(.duplicateReservation) { _ = try await plugin.submit(draftID: duplicate.id, confirmed: true) }
        require(await commands.count() == 1, "Uncertain command was retried")
    }
    let clock = FixtureClock(), availability = AvailabilityFixture(), commands = CommandFixture(.notSent)
    let plugin = simulation(clock, availability, commands), draft = try await plugin.prepare(request(clock))
    require(try await plugin.submit(draftID: draft.id, confirmed: true) == .notSent(.contractUnverified), "Known not-sent result was lost")
    print("PASS timeout, cancellation, empty receipt and uncertain outcome never retry")
}

func checkConcurrentSubmission() async throws {
    let clock = FixtureClock(), availability = AvailabilityFixture(), commands = CommandFixture(.paused)
    let plugin = simulation(clock, availability, commands), input = request(clock)
    let draft = try await plugin.prepare(input), duplicate = try await plugin.prepare(input)
    let first = Task { try await plugin.submit(draftID: draft.id, confirmed: true) }
    while !(await commands.waiting()) { await Task.yield() }
    await expectFailure(.submissionInProgress) { _ = try await plugin.submit(draftID: draft.id, confirmed: true) }
    await expectFailure(.duplicateReservation) { _ = try await plugin.submit(draftID: duplicate.id, confirmed: true) }
    await commands.resume()
    _ = try await first.value
    require(await commands.count() == 1, "Concurrent commands duplicated")

    let secondAvailability = AvailabilityFixture(), secondCommands = CommandFixture()
    let second = simulation(clock, secondAvailability, secondCommands), secondDraft = try await second.prepare(input)
    await secondAvailability.setPaused()
    let checking = Task { try await second.submit(draftID: secondDraft.id, confirmed: true) }
    while !(await secondAvailability.waiting()) { await Task.yield() }
    await expectFailure(.submissionInProgress) { _ = try await second.submit(draftID: secondDraft.id, confirmed: true) }
    clock.advance(120)
    await secondAvailability.resume()
    await expectFailure(.draftExpired) { _ = try await checking.value }
    require(await secondCommands.count() == 0, "Recheck crossed expiry and still dispatched")

    let cancellationClock = FixtureClock(), cancellationAvailability = AvailabilityFixture(), cancellationCommands = CommandFixture()
    let cancellation = simulation(cancellationClock, cancellationAvailability, cancellationCommands)
    let cancellationDraft = try await cancellation.prepare(request(cancellationClock))
    await cancellationAvailability.setPaused()
    let cancelled = Task { try await cancellation.submit(draftID: cancellationDraft.id, confirmed: true) }
    while !(await cancellationAvailability.waiting()) { await Task.yield() }
    cancelled.cancel()
    await cancellationAvailability.resume()
    do { _ = try await cancelled.value; fatalError("Cancelled read dispatched a command") }
    catch is CancellationError {}
    require(await cancellationCommands.count() == 0, "Cancellation before dispatch sent command")
    print("PASS concurrent submit/recheck lock, expiry and cancellation before dispatch")
}

@main struct DaouOfficeWriteChecks {
    static func main() async throws {
        try await checkDisabledAndUnsupported()
        try await checkValidation()
        try await checkDraftAndConfirmation()
        try await checkExpiryAndAvailability()
        try await checkUncertainResults()
        try await checkConcurrentSubmission()
    }
}
