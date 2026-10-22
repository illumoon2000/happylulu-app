import Foundation

public enum ReservationMode: Sendable { case disabled, simulation }
public enum ReservationOperation: Sendable { case create, change, cancel }
public enum ReservationAvailability: Sendable, Equatable { case available, unavailable, unknown }

public enum ReservationFailure: Error, Sendable, Equatable {
    case disabled, contractUnverified, unsupportedOperation, invalidRequest
    case unavailable, availabilityUnknown, availabilityFailed
    case confirmationRequired, draftNotFound, draftExpired
    case submissionInProgress, duplicateReservation
}

/// Internal intent, not a claim about a server's endpoint or payload.
public struct ReservationRequest: Sendable, Equatable {
    public let connectionID: String
    public let accountID: String
    public let resourceID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let timeZoneID: String

    public init(connectionID: String, accountID: String, resourceID: String, title: String,
                start: Date, end: Date, timeZoneID: String) {
        self.connectionID = connectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.resourceID = resourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.start = start
        self.end = end
        self.timeZoneID = timeZoneID
    }

    fileprivate func validate(at now: Date) throws {
        guard !connectionID.isEmpty, !accountID.isEmpty, !resourceID.isEmpty, !title.isEmpty,
              TimeZone(identifier: timeZoneID) != nil,
              now.timeIntervalSince1970.isFinite,
              start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              start > now, end > start else { throw ReservationFailure.invalidRequest }
    }
}

public struct ReservationDraft: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let request: ReservationRequest
    public let preparedAt: Date
    public let expiresAt: Date
}

public enum ReservationResult: Sendable, Equatable {
    case confirmed(reservationID: String)
    case notSent(ReservationFailure)
    case uncertain
}

public protocol ReservationAvailabilityTransport: Sendable {
    func availability(for request: ReservationRequest) async throws -> ReservationAvailability
}

public protocol ReservationCommandTransport: Sendable {
    /// Return confirmed only after explicit evidence of creation with an identifier.
    /// Return notSent only when no command could have reached the service.
    func create(_ request: ReservationRequest, requestID: UUID) async throws -> ReservationResult
}

/// No production contract has been verified. This type performs no I/O.
public struct UnimplementedReservationTransport: ReservationAvailabilityTransport, ReservationCommandTransport {
    public init() {}
    public func availability(for request: ReservationRequest) async throws -> ReservationAvailability {
        throw ReservationFailure.contractUnverified
    }
    public func create(_ request: ReservationRequest, requestID: UUID) async throws -> ReservationResult {
        .notSent(.contractUnverified)
    }
}

/// Simulation only. This module is deliberately not registered with the app host.
public actor DaouOfficeWritePlugin {
    public static let id = "daouoffice-write"
    private let mode: ReservationMode
    private let availability: any ReservationAvailabilityTransport
    private let commands: any ReservationCommandTransport
    private let now: @Sendable () -> Date
    private var drafts: [UUID: ReservationDraft] = [:]
    private var attempts: [ReservationKey: Attempt] = [:]

    // shortcut: this journal is memory-only; a live adapter requires durable reconciliation first.
    private struct ReservationKey: Hashable {
        let connectionID: String
        let accountID: String
        let resourceID: String
        let start: Date
        let end: Date
        init(_ request: ReservationRequest) {
            connectionID = request.connectionID
            accountID = request.accountID
            resourceID = request.resourceID
            start = request.start
            end = request.end
        }
    }

    private struct Attempt {
        let draftID: UUID
        var result: ReservationResult?
    }

    public init(mode: ReservationMode = .disabled,
                availability: any ReservationAvailabilityTransport = UnimplementedReservationTransport(),
                commands: any ReservationCommandTransport = UnimplementedReservationTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.mode = mode
        self.availability = availability
        self.commands = commands
        self.now = now
    }

    public func prepare(_ request: ReservationRequest, operation: ReservationOperation = .create) async throws -> ReservationDraft {
        guard mode == .simulation else { throw ReservationFailure.disabled }
        guard operation == .create else { throw ReservationFailure.unsupportedOperation }
        try request.validate(at: now())
        try Task.checkCancellation()
        try await checkAvailability(request)
        try Task.checkCancellation()
        let preparedAt = now()
        try request.validate(at: preparedAt)
        let draft = ReservationDraft(id: UUID(), request: request, preparedAt: preparedAt,
                                     expiresAt: preparedAt.addingTimeInterval(120))
        drafts[draft.id] = draft
        return draft
    }

    public func submit(draftID: UUID, confirmed: Bool) async throws -> ReservationResult {
        guard mode == .simulation else { throw ReservationFailure.disabled }
        guard confirmed else { throw ReservationFailure.confirmationRequired }
        guard let draft = drafts[draftID] else { throw ReservationFailure.draftNotFound }
        let key = ReservationKey(draft.request)
        if let attempt = attempts[key] {
            guard attempt.draftID == draftID else { throw ReservationFailure.duplicateReservation }
            guard let result = attempt.result else { throw ReservationFailure.submissionInProgress }
            return result
        }
        try validate(draft)
        try Task.checkCancellation()
        // Reserve before awaiting the read so actor reentrancy cannot dispatch twice.
        attempts[key] = Attempt(draftID: draftID, result: nil)
        do {
            try await checkAvailability(draft.request)
            try Task.checkCancellation()
            try validate(draft)
        } catch {
            attempts.removeValue(forKey: key)
            throw error
        }

        let result: ReservationResult
        do {
            let response = try await commands.create(draft.request, requestID: draftID)
            if case .confirmed(let reservationID) = response,
               reservationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = .uncertain
            } else {
                result = response
            }
        } catch {
            // An error after dispatch does not prove the server rejected the command.
            result = .uncertain
        }
        attempts[key]?.result = result
        return result
    }

    private func validate(_ draft: ReservationDraft) throws {
        let current = now()
        guard current >= draft.preparedAt, current < draft.expiresAt else { throw ReservationFailure.draftExpired }
        try draft.request.validate(at: current)
    }

    private func checkAvailability(_ request: ReservationRequest) async throws {
        let state: ReservationAvailability
        do {
            state = try await availability.availability(for: request)
        } catch ReservationFailure.contractUnverified {
            throw ReservationFailure.contractUnverified
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReservationFailure.availabilityFailed
        }
        switch state {
        case .available: return
        case .unavailable: throw ReservationFailure.unavailable
        case .unknown: throw ReservationFailure.availabilityUnknown
        }
    }
}
