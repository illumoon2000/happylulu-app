@preconcurrency import EventKit
import CryptoKit
import Foundation
import CalendarSyncCore

public enum SystemCalendarError: Error, LocalizedError, Sendable {
    case accessDenied
    case calendarMissing
    case calendarReadOnly
    case eventMissing
    case eventChanged
    case invalidDate
    case writeNotAttempted
    case uncertainWrite

    public var errorDescription: String? {
        switch self {
        case .accessDenied: "Mac 캘린더 접근을 허용해 주세요"
        case .calendarMissing: "선택한 시스템 캘린더를 찾을 수 없습니다"
        case .calendarReadOnly: "선택한 캘린더에 일정을 쓸 수 없습니다"
        case .eventMissing: "일정을 확인할 수 없습니다. 캘린더를 새로고침해 주세요."
        case .eventChanged: "일정이 확인하는 동안 변경됐습니다"
        case .invalidDate: "일정 날짜를 읽을 수 없습니다"
        case .writeNotAttempted: "날짜 오류로 일정 저장을 시작하지 못했습니다"
        case .uncertainWrite: "이전 일정 저장 결과를 확인할 수 없어 재시도를 보류했어요. 캘린더에서 복사된 일정을 확인해 주세요."
        }
    }
}

public struct SystemCalendarSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let accountName: String
    public let accountID: String
    public let colorHex: String

    public init(id: String, title: String, accountName: String, accountID: String, colorHex: String) {
        self.id = id
        self.title = title
        self.accountName = accountName
        self.accountID = accountID
        self.colorHex = colorHex
    }
}

/// Reads the accounts already configured in macOS Calendar. HappyLulu never
/// receives the Google or CalDAV passwords used by Internet Accounts.
public struct SystemCalendarDisplayEvent: Identifiable, Sendable {
    public let id: String
    public let calendarID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let location: String?
}

public actor SystemCalendarAccess {
    private let store = EKEventStore()

    public init() {}

    public func requestAccess() async throws {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await store.requestFullAccessToEvents()
        } else {
            granted = try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { allowed, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: allowed) }
                }
            }
        }
        guard granted else { throw SystemCalendarError.accessDenied }
    }

    public func writableCalendars() throws -> [SystemCalendarSummary] {
        guard EKEventStore.authorizationStatus(for: .event) == .authorized || fullAccessGranted else {
            throw SystemCalendarError.accessDenied
        }
        return store.calendars(for: .event)
            .filter { $0.allowsContentModifications && $0.source.sourceType == .calDAV }
            .map { calendar in
                SystemCalendarSummary(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    accountName: calendar.source.title,
                    accountID: calendar.source.sourceIdentifier,
                    colorHex: Self.hex(calendar.cgColor)
                )
            }
            .sorted {
                ($0.accountName.localizedCaseInsensitiveCompare($1.accountName) == .orderedAscending) ||
                ($0.accountName == $1.accountName &&
                 $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending)
            }
    }

    /// Display includes recurring/invited events even when the sync writer cannot safely copy them.
    public func displayEvents(calendarIDs: [String], start: Date, end: Date) throws -> [SystemCalendarDisplayEvent] {
        guard start < end else { throw SystemCalendarError.invalidDate }
        guard !calendarIDs.isEmpty else { return [] }
        guard EKEventStore.authorizationStatus(for: .event) == .authorized || fullAccessGranted else {
            throw SystemCalendarError.accessDenied
        }
        let selected = try Set(calendarIDs).map { id in
            guard let calendar = store.calendar(withIdentifier: id) else { throw SystemCalendarError.calendarMissing }
            return calendar
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        return store.events(matching: predicate).map { event in
            SystemCalendarDisplayEvent(
                id: "\(event.calendar.calendarIdentifier)|\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)",
                calendarID: event.calendar.calendarIdentifier, title: event.title ?? "제목 없음",
                start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, location: event.location)
        }.sorted { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }
    }

    private var fullAccessGranted: Bool {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
        return false
    }

    private static func hex(_ color: CGColor) -> String {
        guard let components = color.components, components.count >= 3 else { return "#6B8F87" }
        let red = Int((components[0] * 255).rounded())
        let green = Int((components[1] * 255).rounded())
        let blue = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

/// Missing EventKit items are unverified absences, never remote tombstones.
public actor SystemCalendarProvider: CalendarProvider {
    public nonisolated let side: CalendarSide
    private let backend: any SystemCalendarBackend

    public init(side: CalendarSide, calendarID: String) {
        self.side = side
        self.backend = EventKitCalendarBackend(calendarID: calendarID)
    }

    init(side: CalendarSide, backend: any SystemCalendarBackend) {
        self.side = side
        self.backend = backend
    }

    public func fetchChanges(cursor: String?, pageToken: String?) async throws -> CalendarChangePage {
        try backend.validateCalendar()
        let now = Date()
        let events = try backend.events(start: now.addingTimeInterval(-30 * 86_400),
                                        end: now.addingTimeInterval(365 * 86_400))
        let marked = Dictionary(grouping: events.filter { $0.event.syncMarker != nil },
                                by: { $0.event.syncMarker! })
        guard marked.values.allSatisfy({ Set($0.map(\.physicalID)).count == 1 }) else {
            throw SystemCalendarError.uncertainWrite
        }
        let identities = Dictionary(grouping: events, by: { $0.event.id })
        var observed: [CalendarEvent] = []
        for id in identities.keys.sorted() {
            guard let records = identities[id], let first = records.sorted(by: { $0.physicalID < $1.physicalID }).first else { continue }
            var event = first.event
            if Set(records.map(\.physicalID)).count > 1 {
                guard id.hasPrefix("occurrence:") else { throw SystemCalendarError.uncertainWrite }
                // An ambiguous recurrence is visible for review but cannot be
                // planned or copied. Independent occurrences may still sync.
                event.exclusion = .other("ambiguousOccurrence")
            }
            observed.append(event)
        }
        return CalendarChangePage(changes: observed.map(CalendarChange.upsert), isFullSnapshot: true)
    }

    public func observe(eventID: String) async throws -> CalendarObservation {
        try backend.validateCalendar()
        do {
            guard let event = try backend.event(id: eventID) else { return .unavailable(.unknown) }
            return .present(event)
        } catch SystemCalendarError.uncertainWrite {
            // A legacy UID may now refer to a series or multiple occurrences.
            // Its uncertainty holds this mapping without aborting unrelated
            // work. Write and recovery paths retain their strict rejection.
            return .unavailable(.unknown)
        }
    }

    public func apply(_ operation: SyncOperation) async throws -> CalendarWriteReceipt {
        try backend.validateCalendar()
        switch operation {
        case let .create(mappingID, target, _, content):
            guard target == side else { throw CalendarProviderError.wrongSide }
            let marker = try SystemCalendarSafety.markerURL(mappingID)
            let existing = try matchingCreatedEvent(mappingID: mappingID, content: content)
            let event = try existing ?? backend.create(content: content, marker: marker.absoluteString)
            return CalendarWriteReceipt(eventID: event.id, version: event.version)
        case let .update(_, target, id, expectedVersion, content):
            guard target == side else { throw CalendarProviderError.wrongSide }
            guard try backend.event(id: id)?.protectedSource != true else { throw CalendarCodecError.unsupportedEvent }
            let event = try backend.update(id: id, expectedVersion: expectedVersion, content: content)
            return CalendarWriteReceipt(eventID: event.id, version: event.version)
        case let .delete(_, target, id, expectedVersion):
            guard target == side else { throw CalendarProviderError.wrongSide }
            guard try backend.event(id: id)?.protectedSource != true else { throw CalendarCodecError.unsupportedEvent }
            try backend.delete(id: id, expectedVersion: expectedVersion)
            return CalendarWriteReceipt(eventID: id, version: nil)
        }
    }

    public func recover(_ operation: SyncOperation) async throws -> CalendarWriteReceipt {
        // EventKit has no caller-specified ID or conditional create. If the app
        // stopped after saving, recover by marker; never blindly create again.
        if case let .create(mappingID, target, _, content) = operation {
            guard target == side else { throw CalendarProviderError.wrongSide }
            // The previous adapter truncated macOS all-day end times into an
            // empty date interval. Its dates(for:) check always failed before
            // backend.create, so only this provably unwritten journal is safe
            // to discard and replan from a fresh source observation.
            if case let .allDay(start, end) = content.time, start == end {
                throw SystemCalendarError.writeNotAttempted
            }
            try backend.validateCalendar()
            guard let event = try matchingCreatedEvent(mappingID: mappingID, content: content) else {
                throw SystemCalendarError.uncertainWrite
            }
            return CalendarWriteReceipt(eventID: event.id, version: event.version)
        }
        return try await apply(operation)
    }

    private func matchingCreatedEvent(mappingID: String, content: CalendarEventContent) throws -> CalendarEvent? {
        let markerURL = try SystemCalendarSafety.markerURL(mappingID)
        guard let marker = SystemCalendarSafety.marker(from: markerURL) else {
            throw SystemCalendarError.uncertainWrite
        }
        let (start, end) = try SystemCalendarSafety.dates(for: content.time)
        let now = Date()
        var events = try backend.events(start: now.addingTimeInterval(-30 * 86_400),
                                        end: now.addingTimeInterval(365 * 86_400))
        events += try backend.events(start: start.addingTimeInterval(-86_400),
                                     end: end.addingTimeInterval(86_400))
        let matches = Dictionary(events.filter { $0.event.syncMarker == marker }.map { ($0.physicalID, $0) },
                                 uniquingKeysWith: { first, _ in first })
        guard matches.count <= 1 else { throw SystemCalendarError.uncertainWrite }
        return matches.values.first?.event
    }
}

/// Serialized by SystemCalendarProvider. EventKit objects never leave this bridge.
private final class EventKitCalendarBackend: SystemCalendarBackend, @unchecked Sendable {
    private let calendarID: String
    private let store = EKEventStore()

    init(calendarID: String) { self.calendarID = calendarID }

    func validateCalendar() throws { _ = try selectedCalendar() }

    private func selectedCalendar() throws -> EKCalendar {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            guard status == .fullAccess else { throw SystemCalendarError.accessDenied }
        } else {
            guard status == .authorized else { throw SystemCalendarError.accessDenied }
        }
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            throw SystemCalendarError.calendarMissing
        }
        guard calendar.allowsContentModifications else { throw SystemCalendarError.calendarReadOnly }
        return calendar
    }

    func events(start: Date, end: Date) throws -> [SystemCalendarRecord] {
        let calendar = try selectedCalendar()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return try store.events(matching: predicate).map { event in
            guard let id = event.eventIdentifier else { throw SystemCalendarError.eventMissing }
            let decoded = try decode(event)
            return SystemCalendarRecord(physicalID: id + "|" + decoded.id, event: decoded)
        }
    }

    func event(id: String) throws -> CalendarEvent? {
        try find(id: id).map(decode)
    }

    private func find(id: String) throws -> EKEvent? {
        _ = try selectedCalendar()
        if id.hasPrefix("occurrence:") {
            // Search actual occurrences, not EventKit's first-occurrence UID
            // shortcut. Moved exceptions keep their original occurrenceDate.
            let now = Date()
            let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-30 * 86_400),
                end: now.addingTimeInterval(365 * 86_400), calendars: [try selectedCalendar()])
            return try SystemCalendarSafety.matchingOccurrence(id: id, events: store.events(matching: predicate))
        }
        if id.hasPrefix("external:") {
            let matches = store.calendarItems(withExternalIdentifier: String(id.dropFirst(9)))
                .compactMap { $0 as? EKEvent }
                .filter { $0.calendar.calendarIdentifier == calendarID }
            guard matches.count <= 1 else { throw SystemCalendarError.uncertainWrite }
            guard !matches.contains(where: { $0.hasRecurrenceRules || $0.isDetached }) else {
                // A legacy UID-only journal cannot identify a specific member
                // of a series, so it must not edit the first occurrence.
                throw SystemCalendarError.uncertainWrite
            }
            return matches.first
        }
        if id.hasPrefix("sync:") {
            let now = Date()
            let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-30 * 86_400),
                end: now.addingTimeInterval(365 * 86_400), calendars: [try selectedCalendar()])
            let matches = store.events(matching: predicate).filter {
                SystemCalendarSafety.marker(from: $0.url) == String(id.dropFirst(5))
            }
            guard matches.count <= 1 else { throw SystemCalendarError.uncertainWrite }
            return matches.first
        }
        // Compatibility for a journal made by the earlier, unverified prototype.
        guard let event = store.event(withIdentifier: id),
              event.calendar.calendarIdentifier == calendarID else { return nil }
        return event
    }

    func create(content: CalendarEventContent, marker: String) throws -> CalendarEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = try selectedCalendar()
        event.url = URL(string: marker)
        try apply(content, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        return try decode(event)
    }

    func update(id: String, expectedVersion: String, content: CalendarEventContent) throws -> CalendarEvent {
        let event = try editable(id: id, expectedVersion: expectedVersion)
        try apply(content, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        return try decode(event)
    }

    func delete(id: String, expectedVersion: String) throws {
        let event = try editable(id: id, expectedVersion: expectedVersion)
        try store.remove(event, span: .thisEvent, commit: true)
    }

    private func editable(id: String, expectedVersion: String) throws -> EKEvent {
        guard let event = try find(id: id) else { throw SystemCalendarError.eventMissing }
        let decoded = try decode(event)
        guard decoded.version == expectedVersion else { throw SystemCalendarError.eventChanged }
        guard decoded.exclusion == nil, decoded.protectedSource != true else { throw CalendarCodecError.unsupportedEvent }
        return event
    }

    private func decode(_ event: EKEvent) throws -> CalendarEvent {
        guard let eventID = event.eventIdentifier else { throw SystemCalendarError.eventMissing }
        return try SystemCalendarSafety.decodeEvent(event, localID: eventID)
    }

    private func apply(_ content: CalendarEventContent, to event: EKEvent) throws {
        let (start, end) = try SystemCalendarSafety.eventKitDates(for: content.time)
        event.title = content.title
        event.notes = content.notes
        event.location = content.location
        switch content.time {
        case .allDay:
            event.isAllDay = true
            event.timeZone = nil
        case let .timed(_, _, timeZoneID):
            guard let zone = TimeZone(identifier: timeZoneID) else { throw SystemCalendarError.invalidDate }
            event.isAllDay = false
            event.timeZone = zone
        }
        event.startDate = start
        event.endDate = end
        event.alarms = try SystemCalendarSafety.eventKitAlarms(content.alarms)
    }


}
