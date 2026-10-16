import Foundation
import CryptoKit
import CalendarSyncCore

public enum SyncCoordinatorError: Error, LocalizedError, Sendable {
    case notConfigured
    case previewRequired
    case alreadyRunning
    case previewChanged
    case conflictChanged

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "동기화할 캘린더 두 개를 먼저 선택해 주세요"
        case .previewRequired: "처음 동기화할 내용을 먼저 확인해 주세요"
        case .alreadyRunning: "캘린더 동기화가 이미 진행 중입니다"
        case .previewChanged: "미리보기 이후 일정이 바뀌었거나 이전 미리보기의 안전 정보를 확인할 수 없습니다. 새 미리보기를 확인한 뒤 다시 시작해 주세요"
        case .conflictChanged: "충돌 확인 이후 일정이 바뀌었습니다. 미리보기를 다시 확인한 뒤 적용할 내용을 선택해 주세요"
        }
    }
}

/// Serializes a cycle, persists observations before planning, and journals each remote write.
public actor SyncCoordinator {
    private let store: SyncStore
    private let daou: any CalendarProvider
    private let google: any CalendarProvider
    private var running = false

    public init(store: SyncStore, daou: any CalendarProvider, google: any CalendarProvider) {
        self.store = store
        self.daou = daou
        self.google = google
    }

    public func resolveConflict(mappingID: String, prefer side: CalendarSide) async throws {
        guard !running else { throw SyncCoordinatorError.alreadyRunning }
        running = true
        defer { running = false }
        try Task.checkCancellation()
        var state = try await store.load()
        guard state.configuration.hasSelectedPair else { throw SyncCoordinatorError.notConfigured }
        guard state.configuration.enabled, state.configuration.previewAccepted else {
            throw SyncCoordinatorError.previewRequired
        }
        // Only the normal first cycle can validate the approved snapshot.
        // Conflict resolution must not bypass that gate or an uncertain journal.
        guard !(state.configuration.daouBaseURL == "eventkit" && state.lastSuccessAt == nil),
              state.pendingOperations[mappingID] == nil else {
            throw SyncCoordinatorError.previewRequired
        }
        guard let conflict = state.conflicts[mappingID], var mapping = state.mappings[mappingID] else {
            throw SyncCoordinatorError.notConfigured
        }
        let daouID = eventID(in: conflict.daou) ?? mapping.daouEventID
        let googleID = eventID(in: conflict.google) ?? mapping.googleEventID
        // A proposed initial pair can have two one-sided mappings. Preserve the
        // safety history of every mapping that would be collapsed into this pair.
        let related = state.mappings.values.filter { candidate in
            candidate.id == mappingID ||
                ((daouID != nil && candidate.daouEventID == daouID) ||
                 (googleID != nil && candidate.googleEventID == googleID))
        }
        guard !related.contains(where: { state.pendingOperations[$0.id] != nil }) else {
            throw SyncCoordinatorError.previewRequired
        }
        let protection = Set(related.flatMap { $0.protectedSources ?? [] })
        mapping.protectedSources = protection.isEmpty ? nil : protection.sorted { $0.rawValue < $1.rawValue }
        let daouObservation = try await refreshedObservation(.daou, eventID: daouID)
        let googleObservation = try await refreshedObservation(.google, eventID: googleID)
        guard daouObservation == conflict.daou, googleObservation == conflict.google else {
            throw SyncCoordinatorError.conflictChanged
        }
        let chosen = side == .daou ? daouObservation : googleObservation
        let target = side.opposite == .daou ? daouObservation : googleObservation
        guard !(mapping.protectedSources?.contains(side.opposite) ?? false) else {
            throw CalendarCodecError.unsupportedEvent
        }
        if case .present(let event) = target, event.protectedSource == true {
            throw CalendarCodecError.unsupportedEvent
        }
        for observation in [chosen, target] {
            if case let .present(event) = observation, event.exclusion != nil {
                throw CalendarCodecError.unsupportedEvent
            }
        }

        mapping.daouEventID = daouID
        mapping.googleEventID = googleID
        state.mappings[mappingID] = mapping
        if conflict.reason == .initialPairAmbiguous {
            let duplicateIDs = state.mappings.values.filter { candidate in
                candidate.id != mappingID &&
                    ((daouID != nil && candidate.daouEventID == daouID) ||
                     (googleID != nil && candidate.googleEventID == googleID))
            }.map(\.id)
            for id in duplicateIDs {
                state.mappings.removeValue(forKey: id)
                state.conflicts.removeValue(forKey: id)
            }
        }
        state.conflicts = state.conflicts.filter { _, item in
            let itemDaouID = eventID(in: item.daou)
            let itemGoogleID = eventID(in: item.google)
            return item.mappingID == mappingID || itemDaouID != daouID || itemGoogleID != googleID
        }

        let operation: SyncOperation?
        let baseline: SyncBaseline
        switch (chosen, target) {
        case let (.present(source), .present(destination)):
            guard !destination.version.isEmpty else { throw CalendarCodecError.missingVersion }
            baseline = .content(source.content)
            operation = .update(mappingID: mappingID, target: side.opposite,
                targetEventID: destination.id, expectedVersion: destination.version, content: source.content)
        case let (.present(source), .confirmedDeleted), let (.present(source), .absent):
            baseline = .content(source.content)
            operation = .create(mappingID: mappingID, target: side.opposite,
                sourceEventID: source.id, content: source.content)
        case let (.confirmedDeleted, .present(destination)):
            guard !destination.version.isEmpty else { throw CalendarCodecError.missingVersion }
            baseline = .deleted
            operation = .delete(mappingID: mappingID, target: side.opposite,
                targetEventID: destination.id, expectedVersion: destination.version)
        case (.confirmedDeleted, .confirmedDeleted):
            baseline = .deleted
            operation = nil
        default:
            throw CalendarObservationError.incompletePage
        }

        if let operation {
            let pending = PendingSyncOperation(id: mappingID, operation: operation, newBaseline: baseline)
            state.pendingOperations[mappingID] = pending
            try Task.checkCancellation()
            try await store.save(state)
            try Task.checkCancellation()
            let receipt = try await provider(side.opposite).apply(operation)
            applyReceipt(receipt, for: pending, to: &state)
        } else {
            mapping.baseline = baseline
            state.mappings[mappingID] = mapping
            state.conflicts.removeValue(forKey: mappingID)
        }
        try Task.checkCancellation()
        try await store.save(state)
    }

    private func provider(_ side: CalendarSide) -> any CalendarProvider {
        side == .daou ? daou : google
    }

    private func eventID(in observation: CalendarObservation) -> String? {
        if case let .present(event) = observation { return event.id }
        return nil
    }

    private func refreshedObservation(_ side: CalendarSide, eventID: String?) async throws -> CalendarObservation {
        guard let eventID else { return .absent }
        try Task.checkCancellation()
        return try await provider(side).observe(eventID: eventID)
    }

    public func run(allowWrites: Bool) async throws -> SyncRunSummary {
        guard !running else { throw SyncCoordinatorError.alreadyRunning }
        running = true
        defer { running = false }
        try Task.checkCancellation()
        var state = try await store.load()
        guard state.configuration.hasSelectedPair else { throw SyncCoordinatorError.notConfigured }
        if allowWrites, (!state.configuration.enabled || !state.configuration.previewAccepted) {
            throw SyncCoordinatorError.previewRequired
        }
        let firstSystemCycle = state.configuration.daouBaseURL == "eventkit" && state.lastSuccessAt == nil
        let hadPendingAtStart = !state.pendingOperations.isEmpty
        let approvalWithoutPending = firstSystemCycle && state.initialWriteAuthorized == true
            && !hadPendingAtStart
        var needsFirstSystemApproval = firstSystemCycle && !hadPendingAtStart
            && (!allowWrites || state.initialWriteAuthorized != true)

        do {
            if !allowWrites && needsFirstSystemApproval {
                // A failed refresh must not leave an older preview usable.
                state.lastPreview = nil
                state.initialPreviewFingerprint = nil
                state.initialWriteAuthorized = nil
                state.configuration.previewAccepted = false
                state.configuration.enabled = false
                try Task.checkCancellation()
                try await store.save(state)
            }
            if allowWrites {
                let recovery = try await recoverPending(&state)
                if firstSystemCycle && hadPendingAtStart {
                    // Recover the existing journal first. An uncertain first
                    // write must never authorize newly discovered mappings.
                    if !state.pendingOperations.isEmpty {
                        var held = SyncRunSummary()
                        held.mode = .sync
                        held.held = state.pendingOperations.count
                        held.issues = state.pendingOperations.keys.sorted().map {
                            reviewIssue(mappingID: $0, state: state, reason: "pendingJournal")
                        }
                        held.finishedAt = Date()
                        state.lastPreview = held
                        state.lastErrorCode = "initialPendingUncertain"
                        state.nextRunAt = Date().addingTimeInterval(3600)
                        try Task.checkCancellation()
                        try await store.save(state)
                        return held
                    }
                    if recovery.confirmedWrites > 0 {
                        state.initialWriteAuthorized = true
                    } else {
                        state.initialWriteAuthorized = nil
                        needsFirstSystemApproval = true
                    }
                } else if approvalWithoutPending {
                    // A crash may have happened after journaling but before
                    // any write. Require a fresh comparison if no journal is
                    // available to confirm what happened.
                    state.initialWriteAuthorized = nil
                    needsFirstSystemApproval = true
                }
            }
            try await fetchObservations(&state)
            seedMappings(&state)
            try Task.checkCancellation()
            try await store.save(state)
            if allowWrites && needsFirstSystemApproval {
                guard state.lastPreview != nil,
                      let expected = state.initialPreviewFingerprint,
                      expected == (try previewFingerprint(state)) else {
                    throw SyncCoordinatorError.previewChanged
                }
            }

            var summary = SyncRunSummary()
            summary.mode = allowWrites ? .sync : .preview
            summary.issues = []
            summary.excluded = state.daouObserved.values.filter { $0.exclusion != nil }.count
                + state.googleObserved.values.filter { $0.exclusion != nil }.count
            for (side, events) in [(CalendarSide.daou, state.daouObserved), (.google, state.googleObserved)] {
                for event in events.values.sorted(by: { $0.id < $1.id }) {
                    if let exclusion = event.exclusion {
                        summary.issues?.append(SyncReviewIssue(id: "\(side.rawValue):\(event.id)", side: side,
                            title: event.content.title, reason: SyncReviewIssue.exclusionReason(exclusion)))
                    }
                }
            }
            let duplicateCandidates = initialDuplicateCandidates(state)
            for id in state.mappings.keys.sorted() {
                guard var mapping = state.mappings[id] else { continue }
                // An unresolved write keeps its journal and must not be
                // replanned, but it should not block independent mappings.
                if state.pendingOperations[id] != nil {
                    summary.held += 1
                    summary.issues?.append(reviewIssue(mappingID: id, state: state, reason: "pendingJournal"))
                    continue
                }
                if let candidate = duplicateCandidates[id] {
                    state.conflicts[id] = candidate
                    summary.conflicts += 1
                    continue
                }
                let daouObservation = try await observe(.daou, eventID: mapping.daouEventID, state: state)
                let googleObservation = try await observe(.google, eventID: mapping.googleEventID, state: state)
                for (side, observation) in [(CalendarSide.daou, daouObservation), (.google, googleObservation)] {
                    if case .present(let event) = observation, event.protectedSource == true,
                       !(mapping.protectedSources?.contains(side) ?? false) {
                        mapping.protectedSources = (mapping.protectedSources ?? []) + [side]
                    }
                }
                state.mappings[id] = mapping

                // A common marker verifies the pair. Older unrelated events need explicit review.
                if mapping.baseline == nil,
                   case let .present(d) = daouObservation,
                   case let .present(g) = googleObservation,
                   d.syncMarker == id, g.syncMarker == id, d.content == g.content {
                    mapping.baseline = .content(d.content)
                    state.mappings[id] = mapping
                    continue
                }

                let decision = SyncPlanner.plan(mapping: mapping, daou: daouObservation, google: googleObservation)
                switch decision {
                case .settled(let baseline):
                    mapping.baseline = baseline
                    state.mappings[id] = mapping
                    state.conflicts.removeValue(forKey: id)
                case .held(let reason):
                    summary.held += 1
                    summary.issues?.append(reviewIssue(mappingID: id, state: state,
                        reason: SyncReviewIssue.holdReason(reason)))
                case .conflict(let conflict):
                    state.conflicts[id] = conflict
                    summary.conflicts += 1
                case .operation(let operation, let newBaseline):
                    let target = operation.target
                    if target == .daou { summary.toDaou += 1 }
                    else { summary.toGoogle += 1 }
                    if allowWrites {
                        let pending = PendingSyncOperation(id: id, operation: operation, newBaseline: newBaseline)
                        state.pendingOperations[id] = pending
                        // The first-write permission and its journal become
                        // durable together. A failure before this point must
                        // compare the preview again on the next attempt.
                        if needsFirstSystemApproval { state.initialWriteAuthorized = true }
                        try Task.checkCancellation()
                        try await store.save(state)
                        let receipt: CalendarWriteReceipt
                        do {
                            try Task.checkCancellation()
                            receipt = try await provider(target).apply(operation)
                        } catch SystemCalendarError.invalidDate {
                            summary.held += 1
                            summary.issues?.append(reviewIssue(mappingID: id, state: state, reason: "invalidDate"))
                            continue
                        } catch SystemCalendarError.uncertainWrite {
                            summary.held += 1
                            summary.issues?.append(reviewIssue(mappingID: id, state: state, reason: "uncertainWrite"))
                            continue
                        }
                        applyReceipt(receipt, for: pending, to: &state)
                        try Task.checkCancellation()
                        try await store.save(state)
                        summary.completed += 1
                    }
                }
            }
            if !allowWrites && needsFirstSystemApproval {
                state.initialPreviewFingerprint = try previewFingerprint(state)
            }
            if allowWrites {
                if !(firstSystemCycle && !state.pendingOperations.isEmpty) {
                    state.lastSuccessAt = Date()
                } else {
                    summary.held = max(summary.held, state.pendingOperations.count)
                    state.lastErrorCode = "initialPendingUncertain"
                }
                state.nextRunAt = Date().addingTimeInterval(3600)
            }
            summary.finishedAt = Date()
            state.lastPreview = summary
            state.lastErrorCode = firstSystemCycle && !state.pendingOperations.isEmpty
                ? "initialPendingUncertain" : nil
            state.consecutiveFailures = 0
            try Task.checkCancellation()
            try await store.save(state)
            return summary
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if case SyncCoordinatorError.previewChanged = error {
                state.configuration.enabled = false
                state.configuration.previewAccepted = false
                state.lastPreview = nil
                state.initialPreviewFingerprint = nil
                state.nextRunAt = nil
                state.lastErrorCode = "previewChanged"
                state.lastFailureCode = "previewChanged"
                state.lastFailureAt = Date()
                state.pauseReason = "previewChanged"
                try Task.checkCancellation()
                try await store.save(state)
                throw error
            }
            state.lastErrorCode = errorCode(error)
            state.lastFailureCode = state.lastErrorCode
            state.lastFailureAt = Date()
            state.consecutiveFailures += 1
            if isAuthenticationFailure(error) {
                state.configuration.enabled = false
                state.nextRunAt = nil
                state.pauseReason = "authenticationRequired"
            } else {
                let delays: [TimeInterval] = [60, 300, 900, 3600]
                let fallback = delays[min(state.consecutiveFailures - 1, delays.count - 1)]
                let delay = retryAfterDelay(from: error) ?? fallback
                state.nextRunAt = Date().addingTimeInterval(delay)
            }
            try Task.checkCancellation()
            try? await store.save(state)
            throw error
        }
    }

    private func reviewIssue(mappingID: String, state: CalendarSyncState, reason: String) -> SyncReviewIssue {
        let mapping = state.mappings[mappingID]
        if let id = mapping?.daouEventID, let event = state.daouObserved[id] {
            return SyncReviewIssue(id: "mapping:" + mappingID, side: .daou,
                                   title: event.content.title, reason: reason)
        }
        if let id = mapping?.googleEventID, let event = state.googleObserved[id] {
            return SyncReviewIssue(id: "mapping:" + mappingID, side: .google,
                                   title: event.content.title, reason: reason)
        }
        return SyncReviewIssue(id: "mapping:" + mappingID, side: .daou, title: "", reason: reason)
    }

    private func previewFingerprint(_ state: CalendarSyncState) throws -> String {
        struct Snapshot: Encodable {
            let calendarIDs: [String]
            let daou: [String: CalendarEvent]
            let google: [String: CalendarEvent]
            let mappings: [String: CalendarMapping]
            let conflicts: [String: SyncConflict]
        }
        let snapshot = Snapshot(
            calendarIDs: [state.configuration.daouCalendarURL ?? "", state.configuration.googleCalendarID ?? ""],
            daou: state.daouObserved,
            google: state.googleObserved,
            mappings: state.mappings,
            conflicts: state.conflicts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(snapshot))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func errorCode(_ error: Error) -> String {
        if case CalendarHTTPError.httpStatus(let status, _) = error { return "http:\(status)" }
        if let error = error as? SystemCalendarError {
            switch error {
            case .accessDenied: return "accessDenied"
            case .calendarMissing: return "calendarMissing"
            case .calendarReadOnly: return "calendarReadOnly"
            case .eventMissing: return "eventMissing"
            case .eventChanged: return "eventChanged"
            case .invalidDate: return "invalidDate"
            case .writeNotAttempted: return "writeNotAttempted"
            case .uncertainWrite: return "uncertainWrite"
            }
        }
        return String(describing: type(of: error))
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        if error is GoogleAuthorizationError { return true }
        if case SystemCalendarError.accessDenied = error { return true }
        if case CalDAVError.missingCredential = error { return true }
        if case CalendarHTTPError.httpStatus(let status, _) = error,
           status == 401 || status == 403 { return true }
        return false
    }

    private func retryAfterDelay(from error: Error) -> TimeInterval? {
        guard case CalendarHTTPError.httpStatus(_, let value) = error,
              let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds > 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        let delay = date.timeIntervalSinceNow
        return delay > 0 ? delay : nil
    }

    private func fetchObservations(_ state: inout CalendarSyncState) async throws {
        try Task.checkCancellation()
        let daouPage = try await daou.fetchChanges(cursor: nil, pageToken: nil)
        guard daouPage.nextPageToken == nil else { throw CalendarObservationError.incompletePage }
        var daouEvents: [String: CalendarEvent] = daouPage.isFullSnapshot ? [:] : state.daouObserved
        for change in daouPage.changes {
            switch change {
            case .upsert(let event): daouEvents[event.id] = event
            case .deleted(let id): daouEvents.removeValue(forKey: id)
            }
        }

        let googlePage: CalendarChangePage
        let didFullRefresh: Bool
        do {
            try Task.checkCancellation()
            googlePage = try await google.fetchChanges(cursor: state.googleCursor, pageToken: nil)
            didFullRefresh = state.googleCursor == nil
        } catch CalendarHTTPError.httpStatus(410, _) {
            try Task.checkCancellation()
            googlePage = try await google.fetchChanges(cursor: nil, pageToken: nil)
            didFullRefresh = true
        }
        guard googlePage.nextPageToken == nil,
              googlePage.isFullSnapshot || googlePage.nextCursor != nil else {
            throw CalendarObservationError.incompletePage
        }
        var googleEvents = (didFullRefresh || googlePage.isFullSnapshot) ? [:] : state.googleObserved
        for change in googlePage.changes {
            switch change {
            case .upsert(let event): googleEvents[event.id] = event
            case .deleted(let id): googleEvents.removeValue(forKey: id)
            }
        }
        state.daouObserved = daouEvents
        state.googleObserved = googleEvents
        state.googleCursor = googlePage.isFullSnapshot ? nil : googlePage.nextCursor
        try Task.checkCancellation()
        try await store.save(state)
    }

    private func seedMappings(_ state: inout CalendarSyncState) {
        for side in CalendarSide.allCases {
            let events = side == .daou ? state.daouObserved : state.googleObserved
            let marked = Dictionary(grouping: events.values.filter { $0.syncMarker != nil }, by: { $0.syncMarker! })
            for (marker, candidates) in marked where candidates.count == 1 {
                guard var mapping = state.mappings[marker],
                      mapping.eventID(on: side) == "sync:" + marker,
                      let event = candidates.first, event.id.hasPrefix("external:") else { continue }
                if side == .daou { mapping.daouEventID = event.id }
                else { mapping.googleEventID = event.id }
                state.mappings[marker] = mapping
            }
            // A server may drop the copy's URL before its UID is linked. The
            // resulting unmarked item must not be imported as a new source.
            // Hold new imports on that side until the provisional identity can
            // be verified; do not guess from matching title/time/content.
            let hasUnverifiedCopy = state.mappings.values.contains { mapping in
                guard let id = mapping.eventID(on: side), id.hasPrefix("sync:") else { return false }
                return events[id] == nil
            }
            if hasUnverifiedCopy { continue }
            for event in events.values where event.exclusion == nil {
                if !withinImportWindow(event.content.time),
                   !state.mappings.values.contains(where: { $0.eventID(on: side) == event.id }) { continue }
                if state.mappings.values.contains(where: { $0.eventID(on: side) == event.id }) { continue }
                let marker = event.syncMarker.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
                let id = marker ?? UUID().uuidString
                var mapping = state.mappings[id] ?? CalendarMapping(
                    id: id, daouEventID: nil, googleEventID: nil, baseline: nil)
                if mapping.eventID(on: side) != nil { continue }
                if side == .daou { mapping.daouEventID = event.id }
                else { mapping.googleEventID = event.id }
                state.mappings[id] = mapping
            }
        }
        for id in state.mappings.keys {
            guard var mapping = state.mappings[id] else { continue }
            for (side, events) in [(CalendarSide.daou, state.daouObserved), (.google, state.googleObserved)] {
                guard let eventID = mapping.eventID(on: side), events[eventID]?.protectedSource == true,
                      !(mapping.protectedSources?.contains(side) ?? false) else { continue }
                mapping.protectedSources = (mapping.protectedSources ?? []) + [side]
            }
            state.mappings[id] = mapping
        }
    }

    private func initialDuplicateCandidates(_ state: CalendarSyncState) -> [String: SyncConflict] {
        let daouOnly = state.mappings.values.filter {
            $0.baseline == nil && $0.daouEventID != nil && $0.googleEventID == nil
        }
        let googleOnly = state.mappings.values.filter {
            $0.baseline == nil && $0.googleEventID != nil && $0.daouEventID == nil
        }
        var result: [String: SyncConflict] = [:]
        for d in daouOnly {
            guard let dID = d.daouEventID, let dEvent = state.daouObserved[dID] else { continue }
            for g in googleOnly {
                guard let gID = g.googleEventID, let gEvent = state.googleObserved[gID],
                      dEvent.content.title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(
                        gEvent.content.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame,
                      sameTime(dEvent.content.time, gEvent.content.time) else { continue }
                let dConflict = SyncConflict(mappingID: d.id, reason: .initialPairAmbiguous,
                    baseline: nil, daou: .present(dEvent), google: .present(gEvent))
                let gConflict = SyncConflict(mappingID: g.id, reason: .initialPairAmbiguous,
                    baseline: nil, daou: .present(dEvent), google: .present(gEvent))
                result[d.id] = dConflict
                result[g.id] = gConflict
            }
        }
        return result
    }

    private func sameTime(_ lhs: CalendarEventTime, _ rhs: CalendarEventTime) -> Bool {
        switch (lhs, rhs) {
        case let (.allDay(aStart, aEnd), .allDay(bStart, bEnd)):
            return aStart == bStart && aEnd == bEnd
        case let (.timed(aStart, aEnd, _), .timed(bStart, bEnd, _)):
            return abs(aStart.timeIntervalSince(bStart)) < 1 && abs(aEnd.timeIntervalSince(bEnd)) < 1
        default: return false
        }
    }

    private func withinImportWindow(_ time: CalendarEventTime) -> Bool {
        let now = Date()
        let start = now.addingTimeInterval(-30 * 86_400)
        let end = now.addingTimeInterval(365 * 86_400)
        switch time {
        case let .timed(begin, finish, _): return begin < end && finish >= start
        case let .allDay(begin, finish):
            guard let first = ISO8601DateFormatter().date(from: begin + "T00:00:00Z"),
                  let last = ISO8601DateFormatter().date(from: finish + "T00:00:00Z") else { return false }
            return first < end && last >= start
        }
    }

    private func observe(_ side: CalendarSide, eventID: String?, state: CalendarSyncState) async throws -> CalendarObservation {
        guard let eventID else { return .absent }
        let cached = side == .daou ? state.daouObserved[eventID] : state.googleObserved[eventID]
        if let cached { return .present(cached) }
        try Task.checkCancellation()
        return try await provider(side).observe(eventID: eventID)
    }

    private func applyReceipt(_ receipt: CalendarWriteReceipt, for pending: PendingSyncOperation,
                              to state: inout CalendarSyncState) {
        guard var mapping = state.mappings[pending.id] else { return }
        let target = pending.operation.target
        if target == .daou { mapping.daouEventID = receipt.eventID }
        else { mapping.googleEventID = receipt.eventID }
        mapping.baseline = pending.newBaseline
        state.mappings[pending.id] = mapping
        if case let .content(content) = pending.newBaseline {
            let event = CalendarEvent(id: receipt.eventID, version: receipt.version ?? "",
                                      content: content, syncMarker: pending.id)
            if target == .daou { state.daouObserved[receipt.eventID] = event }
            else { state.googleObserved[receipt.eventID] = event }
        } else {
            if target == .daou { state.daouObserved.removeValue(forKey: receipt.eventID) }
            else { state.googleObserved.removeValue(forKey: receipt.eventID) }
        }
        state.pendingOperations.removeValue(forKey: pending.id)
        state.conflicts.removeValue(forKey: pending.id)
    }

    private struct PendingRecovery {
        var confirmedWrites = 0
    }

    private func recoverPending(_ state: inout CalendarSyncState) async throws -> PendingRecovery {
        var recovery = PendingRecovery()
        for pending in state.pendingOperations.values.sorted(by: { $0.id < $1.id }) {
            if state.mappings[pending.id]?.protectedSources?.contains(pending.operation.target) == true {
                continue
            }
            do {
                try Task.checkCancellation()
                let receipt = try await provider(pending.operation.target).recover(pending.operation)
                applyReceipt(receipt, for: pending, to: &state)
                try Task.checkCancellation()
                try await store.save(state)
                recovery.confirmedWrites += 1
            } catch SystemCalendarError.writeNotAttempted {
                guard case .create = pending.operation else { throw SystemCalendarError.writeNotAttempted }
                state.pendingOperations.removeValue(forKey: pending.id)
                try Task.checkCancellation()
                try await store.save(state)
            } catch SystemCalendarError.invalidDate {
                continue
            } catch SystemCalendarError.uncertainWrite {
                continue
            } catch CalendarCodecError.unsupportedEvent {
                continue
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                guard let targetID = pending.operation.targetEventID else { throw error }
                try Task.checkCancellation()
                let observation = try await provider(pending.operation.target).observe(eventID: targetID)
                switch (pending.operation, observation, pending.newBaseline) {
                case (.update, .present(let current), .content(let content)) where current.content == content:
                    applyReceipt(CalendarWriteReceipt(eventID: current.id, version: current.version),
                                 for: pending, to: &state)
                    try Task.checkCancellation()
                    try await store.save(state)
                    recovery.confirmedWrites += 1
                case (.delete, .confirmedDeleted, .deleted):
                    applyReceipt(CalendarWriteReceipt(eventID: targetID, version: nil),
                                 for: pending, to: &state)
                    try Task.checkCancellation()
                    try await store.save(state)
                    recovery.confirmedWrites += 1
                default:
                    throw error
                }
            }
        }
        return recovery
    }
}

public enum CalendarObservationError: Error, LocalizedError, Sendable {
    case incompletePage
    public var errorDescription: String? { "캘린더 목록이 완전히 조회되지 않았습니다" }
}

private extension SyncOperation {
    var target: CalendarSide {
        switch self {
        case .create(_, let target, _, _), .update(_, let target, _, _, _), .delete(_, let target, _, _): target
        }
    }

    var targetEventID: String? {
        switch self {
        case .create: nil
        case .update(_, _, let id, _, _), .delete(_, _, let id, _): id
        }
    }
}
