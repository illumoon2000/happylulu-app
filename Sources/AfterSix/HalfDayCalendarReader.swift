@preconcurrency import EventKit
import Foundation
import AfterSixCore

/// Attendance only reads event titles after its own explicit calendar opt-in.
/// It never writes or changes CalendarSync's selected calendars or journal.
actor HalfDayCalendarReader {
    private let store = EKEventStore()

    func requestAccess() async throws {
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
        guard granted else { throw CalendarReadError.accessDenied }
    }

    func titles(on date: Date, timeZone: TimeZone) throws -> [String] {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            guard status == .fullAccess else { throw CalendarReadError.accessDenied }
        } else {
            guard status == .authorized else { throw CalendarReadError.accessDenied }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).compactMap(\.title)
    }

    func detect(on date: Date, timeZone: TimeZone) throws -> WorkdayMode? {
        HalfDayRecognition.mode(from: try titles(on: date, timeZone: timeZone))
    }

    enum CalendarReadError: LocalizedError {
        case accessDenied
        var errorDescription: String? { "캘린더 접근을 허용해야 반차 일정을 자동 인식할 수 있습니다." }
    }
}
