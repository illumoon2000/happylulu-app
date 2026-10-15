import Foundation

public enum AppFeature: String, Codable, CaseIterable, Sendable {
    case calendar, leave, halfDay
}

public struct FeatureAdapterDescriptor: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let features: Set<AppFeature>
    public init(id: String, name: String, features: Set<AppFeature>) {
        self.id = id; self.name = name; self.features = features
    }
}

/// Calendar adapters normalize end times to exclusive bounds before exposing them to the app.
public struct FeatureCalendarEvent: Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceID: String
    public let calendarID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let location: String?
    public init(sourceID: String, eventID: String, calendarID: String, title: String,
                start: Date, end: Date, isAllDay: Bool, location: String? = nil) {
        // JSON avoids collisions when an external ID itself contains a separator.
        id = String(decoding: try! JSONEncoder().encode([sourceID, calendarID, eventID]), as: UTF8.self)
        self.sourceID = sourceID; self.calendarID = calendarID; self.title = title
        self.start = start; self.end = end; self.isAllDay = isAllDay; self.location = location
    }
}

public enum FeatureAdapterFailure: Error, Equatable, Sendable {
    case duplicate, unavailable, unsupported, outsideCoverage, missingSnapshot
}

/// Processing boundary shared by built-in services and plugins. No view or credential types.
@MainActor
public protocol FeatureAdapter: AnyObject {
    var descriptor: FeatureAdapterDescriptor { get }
    var calendarTimeZone: TimeZone? { get }
    func calendarEvents(in interval: DateInterval) async throws -> [FeatureCalendarEvent]
    func leaveSnapshot() -> PluginSnapshot?
    func requestHalfDayAccess() async throws
    func halfDayTitles(on day: Date, timeZone: TimeZone) async throws -> [String]
}

public extension FeatureAdapter { var calendarTimeZone: TimeZone? { nil } }

/// Routes each feature independently. Disabling an adapter immediately restores the default.
@MainActor
public final class FeatureAdapterRouter {
    public let defaultID: String
    private var adapters: [String: any FeatureAdapter] = [:]
    private var enabled: Set<String> = []
    private var selected: [AppFeature: String] = [:]
    private var generations: [AppFeature: Int] = [:]
    public private(set) var revision = 0

    public init(defaultAdapter: any FeatureAdapter) {
        defaultID = defaultAdapter.descriptor.id
        adapters[defaultID] = defaultAdapter; enabled.insert(defaultID)
    }
    public var descriptors: [FeatureAdapterDescriptor] {
        adapters.values.map(\.descriptor).sorted { $0.id < $1.id }
    }
    public func register(_ adapter: any FeatureAdapter, enabled isEnabled: Bool = false) throws {
        guard adapters[adapter.descriptor.id] == nil else { throw FeatureAdapterFailure.duplicate }
        adapters[adapter.descriptor.id] = adapter
        if isEnabled { enabled.insert(adapter.descriptor.id) }
        revision += 1
    }
    public func isEnabled(_ id: String) -> Bool { enabled.contains(id) }
    public func setEnabled(_ isEnabled: Bool, for id: String) {
        guard id != defaultID, adapters[id] != nil, enabled.contains(id) != isEnabled else { return }
        if isEnabled { enabled.insert(id) } else {
            enabled.remove(id)
            for (feature, source) in selected where source == id { generations[feature, default: 0] += 1 }
            selected = selected.filter { $0.value != id }
        }
        revision += 1
    }
    public func unregister(_ id: String) {
        guard id != defaultID, adapters[id] != nil else { return }
        setEnabled(false, for: id); adapters[id] = nil; revision += 1
    }
    public func selectedID(for feature: AppFeature) -> String { selected[feature] ?? defaultID }
    public func select(_ id: String, for feature: AppFeature) throws {
        guard enabled.contains(id), let adapter = adapters[id] else { throw FeatureAdapterFailure.unavailable }
        guard adapter.descriptor.features.contains(feature) else { throw FeatureAdapterFailure.unsupported }
        guard selectedID(for: feature) != id else { return }
        selected[feature] = id; generations[feature, default: 0] += 1; revision += 1
    }
    public var selection: [AppFeature: String] { selected }
    public func timeZone(for feature: AppFeature) -> TimeZone? { try? adapter(for: feature).calendarTimeZone }
    private func adapter(for feature: AppFeature) throws -> any FeatureAdapter {
        let id = selectedID(for: feature)
        guard enabled.contains(id), let adapter = adapters[id] else { throw FeatureAdapterFailure.unavailable }
        guard adapter.descriptor.features.contains(feature) else { throw FeatureAdapterFailure.unsupported }
        return adapter
    }
    public func calendarEvents(in interval: DateInterval) async throws -> [FeatureCalendarEvent] {
        try Task.checkCancellation()
        let current = generations[.calendar, default: 0]
        let result = try await adapter(for: .calendar).calendarEvents(in: interval)
        try Task.checkCancellation()
        guard current == generations[.calendar, default: 0] else { throw CancellationError() }
        return result
    }
    public func leaveSnapshot() -> PluginSnapshot? { try? adapter(for: .leave).leaveSnapshot() }
    public func requestHalfDayAccess() async throws {
        try Task.checkCancellation()
        let current = generations[.halfDay, default: 0]
        try await adapter(for: .halfDay).requestHalfDayAccess()
        try Task.checkCancellation()
        guard current == generations[.halfDay, default: 0] else { throw CancellationError() }
    }
    public func halfDayTitles(on day: Date, timeZone: TimeZone) async throws -> [String] {
        try Task.checkCancellation()
        let current = generations[.halfDay, default: 0]
        let source = try adapter(for: .halfDay)
        let result = try await source.halfDayTitles(on: day, timeZone: source.calendarTimeZone ?? timeZone)
        try Task.checkCancellation()
        guard current == generations[.halfDay, default: 0] else { throw CancellationError() }
        return result
    }
}

/// Any registered plugin can bind to app features using the shared immutable snapshot API.
@MainActor
public final class SnapshotFeatureAdapter: FeatureAdapter {
    public let descriptor: FeatureAdapterDescriptor
    private let api: any PluginDataProviding
    private let timeZone: TimeZone
    private let inclusiveAllDayEnd: Bool
    public var calendarTimeZone: TimeZone? { timeZone }
    public init(descriptor: FeatureAdapterDescriptor, api: any PluginDataProviding, timeZone: TimeZone,
                inclusiveAllDayEnd: Bool = false) {
        self.descriptor = descriptor; self.api = api; self.timeZone = timeZone
        self.inclusiveAllDayEnd = inclusiveAllDayEnd
    }
    private func coveredSnapshot(for interval: DateInterval) throws -> PluginSnapshot {
        guard let value = api.snapshot(for: descriptor.id) else { throw FeatureAdapterFailure.missingSnapshot }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        guard let first = value.coverage.calendarFrom, let last = value.coverage.calendarThrough,
              let start = formatter.date(from: first), let through = formatter.date(from: last),
              formatter.string(from: start) == first, formatter.string(from: through) == last,
              let end = calendar.date(byAdding: .day, value: 1, to: through),
              start <= interval.start, end >= interval.end else { throw FeatureAdapterFailure.outsideCoverage }
        return value
    }
    public func calendarEvents(in interval: DateInterval) async throws -> [FeatureCalendarEvent] {
        let value = try coveredSnapshot(for: interval)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return value.events.compactMap { event in
            let end: Date
            if event.isAllDay && (inclusiveAllDayEnd || event.end == nil || event.end == event.start) {
                // Sources with inclusive all-day bounds include the final day, even at midnight.
                guard let next = calendar.date(byAdding: .day, value: 1,
                    to: calendar.startOfDay(for: event.end ?? event.start)) else { return nil }
                end = next
            } else { end = event.end ?? event.start }
            let overlaps = end == event.start ? event.start >= interval.start && event.start < interval.end
                : event.start < interval.end && end > interval.start
            guard overlaps else { return nil }
            return FeatureCalendarEvent(sourceID: descriptor.id, eventID: event.id, calendarID: event.calendarID,
                title: event.title, start: event.start, end: end, isAllDay: event.isAllDay)
        }
    }
    public func leaveSnapshot() -> PluginSnapshot? { api.snapshot(for: descriptor.id) }
    public func requestHalfDayAccess() async throws {
        guard api.snapshot(for: descriptor.id) != nil else { throw FeatureAdapterFailure.missingSnapshot }
    }
    public func halfDayTitles(on day: Date, timeZone: TimeZone) async throws -> [String] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { throw FeatureAdapterFailure.unavailable }
        return try await calendarEvents(in: DateInterval(start: start, end: end)).map(\.title)
    }
}
