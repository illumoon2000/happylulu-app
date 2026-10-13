import Foundation

public struct WorkSettings: Codable, Equatable, Sendable {
    public var workMinutes: Int = 480
    public var breakMinutes: Int = 60
    public init() {}

    public var isValid: Bool {
        (60...960).contains(workMinutes) && (0...240).contains(breakMinutes)
    }
}

public enum ArrivalSource: String, Codable, Sendable {
    case unlock, login, manual
}

public enum WorkdayMode: String, Codable, CaseIterable, Sendable {
    case normal, morningHalf, afternoonHalf

    public var label: String {
        switch self {
        case .normal: "일반 근무"
        case .morningHalf: "오전 반차"
        case .afternoonHalf: "오후 반차"
        }
    }
}

public enum ModeSource: String, Codable, Sendable {
    case legacy, automatic, manual
}

/// A confirmed empty/ambiguous calendar read is different from a failed read.
/// Only failures may reuse the last successfully observed mode.
public enum CalendarModeObservation: Equatable, Sendable {
    case confirmed(WorkdayMode?)
    case unavailable

    public func resolved(previous: WorkdayMode?) -> WorkdayMode? {
        switch self {
        case let .confirmed(mode): mode
        case .unavailable: previous
        }
    }
}

public struct Arrival: Codable, Equatable, Sendable {
    public let day: String
    public let time: Date
    public let source: ArrivalSource
    public let timeZoneID: String
    public let mode: WorkdayMode
    public let modeSource: ModeSource

    public init(day: String, time: Date, source: ArrivalSource, timeZoneID: String,
                mode: WorkdayMode = .normal, modeSource: ModeSource = .legacy) {
        self.day = day
        self.time = time
        self.source = source
        self.timeZoneID = timeZoneID
        self.mode = mode
        self.modeSource = modeSource
    }

    private enum CodingKeys: String, CodingKey { case day, time, source, timeZoneID, mode, modeSource }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        day = try values.decode(String.self, forKey: .day)
        time = try values.decode(Date.self, forKey: .time)
        source = try values.decode(ArrivalSource.self, forKey: .source)
        timeZoneID = try values.decode(String.self, forKey: .timeZoneID)
        mode = try values.decodeIfPresent(WorkdayMode.self, forKey: .mode) ?? .normal
        modeSource = try values.decodeIfPresent(ModeSource.self, forKey: .modeSource) ?? .legacy
    }
}

/// Informational time since the scheduled departure. This is not a record of
/// actual work or an approval of a meal allowance.
public struct PostDepartureStatus: Equatable, Sendable {
    public let extraMinutes: Int?
    public let mealMinutesRemaining: Int
    public var mealThresholdReached: Bool { mealMinutesRemaining == 0 }
}

public struct AttendanceState: Codable, Equatable, Sendable {
    public var version = 1
    public var settings = WorkSettings()
    public var arrivals: [String: Arrival] = [:]
    // A cleared day stays suppressed until the next day or an explicit manual entry.
    public var suppressedDays: Set<String> = []
    public var lastUnlockAt: Date?
    public var didOfferLoginItem = false
    public var detectHalfDaysFromCalendar = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, settings, arrivals, suppressedDays, lastUnlockAt, didOfferLoginItem, detectHalfDaysFromCalendar
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        settings = try values.decode(WorkSettings.self, forKey: .settings)
        arrivals = try values.decode([String: Arrival].self, forKey: .arrivals)
        suppressedDays = try values.decode(Set<String>.self, forKey: .suppressedDays)
        lastUnlockAt = try values.decodeIfPresent(Date.self, forKey: .lastUnlockAt)
        didOfferLoginItem = try values.decode(Bool.self, forKey: .didOfferLoginItem)
        detectHalfDaysFromCalendar = try values.decodeIfPresent(Bool.self, forKey: .detectHalfDaysFromCalendar) ?? false
    }
}

public enum AttendanceError: LocalizedError {
    case invalidTime, invalidSettings, invalidState
    public var errorDescription: String? {
        switch self {
        case .invalidTime: "오늘의 지난 시각을 입력해 주세요. 일반·오후 반차는 08:00~10:00, 오전 반차는 13:00~15:00입니다."
        case .invalidSettings: "근무는 1~16시간, 휴게는 0~4시간으로 설정해 주세요."
        case .invalidState: "기록 파일을 읽을 수 없습니다. 원본을 보존했습니다."
        }
    }
}

public enum Attendance {
    public static let extraTimeDisplayDelayMinutes = 30
    public static let mealReferenceThresholdMinutes = 120

    public static func clockLabel(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }

    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func today(in state: AttendanceState, now: Date, calendar: Calendar) -> Arrival? {
        state.arrivals[dayKey(now, calendar: calendar)]
    }

    public static func isAllowed(_ date: Date, for mode: WorkdayMode, calendar: Calendar) -> Bool {
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        switch mode {
        case .normal, .afternoonHalf: return (8 * 60...10 * 60).contains(minute)
        case .morningHalf: return (13 * 60...15 * 60).contains(minute)
        }
    }

    public static func automaticMode(at date: Date, calendar: Calendar,
                                     calendarMode: WorkdayMode? = nil) -> WorkdayMode? {
        if let calendarMode {
            return isAllowed(date, for: calendarMode, calendar: calendar) ? calendarMode : nil
        }
        if isAllowed(date, for: .normal, calendar: calendar) { return .normal }
        if isAllowed(date, for: .morningHalf, calendar: calendar) { return .morningHalf }
        return nil
    }

    @discardableResult
    public static func recordUnlock(in state: inout AttendanceState, at date: Date, calendar: Calendar,
                                    calendarMode: WorkdayMode? = nil) -> Bool {
        state.lastUnlockAt = date
        return recordAutomatic(in: &state, at: date, source: .unlock, calendar: calendar,
                               calendarMode: calendarMode)
    }

    @discardableResult
    public static func recordLogin(in state: inout AttendanceState, at date: Date, calendar: Calendar,
                                   calendarMode: WorkdayMode? = nil) -> Bool {
        // Observed login-item launch time, never an inferred boot/unlock time.
        recordAutomatic(in: &state, at: date, source: .login, calendar: calendar,
                        calendarMode: calendarMode)
    }

    private static func recordAutomatic(in state: inout AttendanceState, at date: Date,
                                        source: ArrivalSource, calendar: Calendar,
                                        calendarMode: WorkdayMode?) -> Bool {
        let day = dayKey(date, calendar: calendar)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let recordedAt = (6 * 60..<8 * 60).contains(minute)
            ? calendar.date(bySettingHour: 8, minute: 0, second: 0, of: date) ?? date : date
        guard let mode = automaticMode(at: recordedAt, calendar: calendar, calendarMode: calendarMode),
              state.arrivals[day] == nil,
              !state.suppressedDays.contains(day) else { return false }
        state.arrivals[day] = Arrival(day: day, time: recordedAt, source: source,
                                      timeZoneID: calendar.timeZone.identifier,
                                      mode: mode, modeSource: .automatic)
        return true
    }

    public static func setManual(in state: inout AttendanceState, at date: Date, now: Date,
                                 calendar: Calendar, selectedMode: WorkdayMode? = nil,
                                 calendarMode: WorkdayMode? = nil) throws {
        let mode = selectedMode ?? automaticMode(at: date, calendar: calendar, calendarMode: calendarMode)
        guard date <= now, calendar.isDate(date, inSameDayAs: now),
              let mode, isAllowed(date, for: mode, calendar: calendar) else { throw AttendanceError.invalidTime }
        let day = dayKey(now, calendar: calendar)
        state.arrivals[day] = Arrival(day: day, time: date, source: .manual,
                                      timeZoneID: calendar.timeZone.identifier,
                                      mode: mode, modeSource: selectedMode == nil ? .automatic : .manual)
        state.suppressedDays.remove(day)
    }

    @discardableResult
    public static func refreshAutomaticMode(in state: inout AttendanceState, now: Date,
                                            calendar: Calendar, calendarMode: WorkdayMode?) -> Bool {
        let day = dayKey(now, calendar: calendar)
        guard let arrival = state.arrivals[day], arrival.modeSource == .automatic,
              let newMode = automaticMode(at: arrival.time, calendar: calendar, calendarMode: calendarMode)
                ?? automaticMode(at: arrival.time, calendar: calendar),
              newMode != arrival.mode else { return false }
        state.arrivals[day] = Arrival(day: day, time: arrival.time, source: arrival.source,
                                      timeZoneID: arrival.timeZoneID, mode: newMode, modeSource: .automatic)
        return true
    }

    public static func skipToday(in state: inout AttendanceState, now: Date, calendar: Calendar) {
        let day = dayKey(now, calendar: calendar)
        state.arrivals.removeValue(forKey: day)
        state.suppressedDays.insert(day)
    }

    public static func earlyLeaveMinutes(on date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard calendar.component(.weekday, from: date) == 6,
              let nextFriday = calendar.date(byAdding: .day, value: 7, to: date),
              !calendar.isDate(date, equalTo: nextFriday, toGranularity: .month) else { return 0 }
        return 120
    }

    public static func earlyLeaveMinutes(for arrival: Arrival) -> Int {
        earlyLeaveMinutes(on: arrival.time, timeZone: TimeZone(identifier: arrival.timeZoneID) ?? .current)
    }

    public static func departure(for arrival: Arrival, settings: WorkSettings) -> Date {
        if arrival.mode != .normal { return arrival.time.addingTimeInterval(4 * 60 * 60) }
        let minutes = max(0, settings.workMinutes + settings.breakMinutes - earlyLeaveMinutes(for: arrival))
        return arrival.time.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    public static func progress(from arrival: Date, until departure: Date, now: Date) -> Double {
        let duration = departure.timeIntervalSince(arrival)
        guard duration > 0 else { return now >= departure ? 1 : 0 }
        return min(1, max(0, now.timeIntervalSince(arrival) / duration))
    }

    public static func remainingMinutes(until departure: Date, now: Date) -> Int {
        max(0, Int(ceil(departure.timeIntervalSince(now) / 60)))
    }

    public static func postDepartureStatus(in state: AttendanceState, now: Date,
                                           calendar: Calendar) -> PostDepartureStatus? {
        guard !state.suppressedDays.contains(dayKey(now, calendar: calendar)),
              let arrival = today(in: state, now: now, calendar: calendar) else { return nil }
        let elapsed = now.timeIntervalSince(departure(for: arrival, settings: state.settings))
        guard elapsed >= 0 else { return nil }
        let elapsedMinutes = Int(floor(elapsed / 60))
        return PostDepartureStatus(
            extraMinutes: elapsedMinutes >= Self.extraTimeDisplayDelayMinutes ? elapsedMinutes : nil,
            mealMinutesRemaining: max(0, Int(ceil((TimeInterval(Self.mealReferenceThresholdMinutes * 60) - elapsed) / 60)))
        )
    }
}

public struct StateStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static var standard: StateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StateStore(url: base.appendingPathComponent("AfterSix/state.json"))
    }

    public func load() throws -> AttendanceState {
        guard FileManager.default.fileExists(atPath: url.path) else { return AttendanceState() }
        let state = try JSONDecoder().decode(AttendanceState.self, from: Data(contentsOf: url))
        guard state.version == 1, state.settings.isValid,
              hasValidArrivals(state) else { throw AttendanceError.invalidState }
        return state
    }

    private func hasValidArrivals(_ state: AttendanceState) -> Bool {
        state.arrivals.allSatisfy { key, value in
            key == value.day && value.time.timeIntervalSince1970.isFinite
                && TimeZone(identifier: value.timeZoneID) != nil
        }
    }

    public func save(_ state: AttendanceState) throws {
        guard state.version == 1, state.settings.isValid else { throw AttendanceError.invalidSettings }
        guard hasValidArrivals(state) else { throw AttendanceError.invalidState }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
