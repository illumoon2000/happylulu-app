import Foundation

public enum AttendanceCommand: Sendable {
    case login(at: Date, mode: WorkdayMode?)
    case unlock(at: Date, mode: WorkdayMode?)
    case manual(at: Date, now: Date, selectedMode: WorkdayMode?, calendarMode: WorkdayMode?)
    case refreshMode(now: Date, mode: WorkdayMode?)
    case skip(now: Date)
    case settings(work: Int, rest: Int)
}

/// Attendance processing is independent of view models and external data adapters.
public protocol AttendanceAdapter: Sendable {
    func apply(_ command: AttendanceCommand, to state: inout AttendanceState, calendar: Calendar) throws -> Bool
    func today(in state: AttendanceState, now: Date, calendar: Calendar) -> Arrival?
    func departure(for arrival: Arrival, settings: WorkSettings) -> Date
    func remainingMinutes(until departure: Date, now: Date) -> Int
    func postDepartureStatus(in state: AttendanceState, now: Date, calendar: Calendar) -> PostDepartureStatus?
    func earlyLeaveMinutes(for arrival: Arrival) -> Int
    func earlyLeaveMinutes(on date: Date, timeZone: TimeZone) -> Int
    func progress(from arrival: Date, until departure: Date, now: Date) -> Double
    func isAllowed(_ date: Date, for mode: WorkdayMode, calendar: Calendar) -> Bool
    func dayKey(_ date: Date, calendar: Calendar) -> String
    func history(in state: AttendanceState) -> [String: [Arrival]]
}

/// Preserves the established local attendance engine and its storage format.
public struct DefaultAttendanceAdapter: AttendanceAdapter {
    public init() {}
    public func apply(_ command: AttendanceCommand, to state: inout AttendanceState, calendar: Calendar) throws -> Bool {
        switch command {
        case let .login(at, mode): Attendance.recordLogin(in: &state, at: at, calendar: calendar, calendarMode: mode)
        case let .unlock(at, mode): Attendance.recordUnlock(in: &state, at: at, calendar: calendar, calendarMode: mode)
        case let .manual(at, now, selectedMode, calendarMode):
            try Attendance.setManual(in: &state, at: at, now: now, calendar: calendar,
                selectedMode: selectedMode, calendarMode: calendarMode)
        case let .refreshMode(now, mode):
            return Attendance.refreshAutomaticMode(in: &state, now: now, calendar: calendar, calendarMode: mode)
        case let .skip(now): Attendance.skipToday(in: &state, now: now, calendar: calendar)
        case let .settings(work, rest):
            var settings = state.settings
            settings.workMinutes = work; settings.breakMinutes = rest
            guard settings.isValid else { throw AttendanceError.invalidSettings }
            state.settings = settings
        }
        return true
    }
    public func today(in state: AttendanceState, now: Date, calendar: Calendar) -> Arrival? { Attendance.today(in: state, now: now, calendar: calendar) }
    public func departure(for arrival: Arrival, settings: WorkSettings) -> Date { Attendance.departure(for: arrival, settings: settings) }
    public func remainingMinutes(until departure: Date, now: Date) -> Int { Attendance.remainingMinutes(until: departure, now: now) }
    public func postDepartureStatus(in state: AttendanceState, now: Date, calendar: Calendar) -> PostDepartureStatus? { Attendance.postDepartureStatus(in: state, now: now, calendar: calendar) }
    public func earlyLeaveMinutes(for arrival: Arrival) -> Int { Attendance.earlyLeaveMinutes(for: arrival) }
    public func earlyLeaveMinutes(on date: Date, timeZone: TimeZone) -> Int { Attendance.earlyLeaveMinutes(on: date, timeZone: timeZone) }
    public func progress(from arrival: Date, until departure: Date, now: Date) -> Double { Attendance.progress(from: arrival, until: departure, now: now) }
    public func isAllowed(_ date: Date, for mode: WorkdayMode, calendar: Calendar) -> Bool { Attendance.isAllowed(date, for: mode, calendar: calendar) }
    public func dayKey(_ date: Date, calendar: Calendar) -> String { Attendance.dayKey(date, calendar: calendar) }
    public func history(in state: AttendanceState) -> [String: [Arrival]] {
        Dictionary(grouping: state.arrivals.values, by: Attendance.historyDay).mapValues { $0.sorted { $0.time < $1.time } }
    }
}
