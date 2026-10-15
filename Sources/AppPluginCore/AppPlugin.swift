import Foundation

public struct PluginDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum PluginFailure: Error, Sendable {
    case invalidAddress, missingCredentials, authentication, interactionRequired
    case unsupportedResponse, timeout, network, configuration, credentials
    case duplicatePlugin, unavailable, busy, disabled
}

public struct PluginLeaveBalance: Codable, Sendable, Equatable {
    public let totalDays: Double
    public let usedDays: Double
    public let remainingDays: Double
    public init(totalDays: Double, usedDays: Double, remainingDays: Double) {
        self.totalDays = totalDays; self.usedDays = usedDays; self.remainingDays = remainingDays
    }
}

public struct PluginVacation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let status: String
    public let days: Double?
    /// Explicit local dates shown by the source. Missing weekends are never filled in.
    public let dates: [String]
    public let periodLabel: String
    public let durationLabel: String
    public let rangeStart: String?
    public let rangeEnd: String?
    public init(id: String, kind: String, status: String, days: Double?, dates: [String], periodLabel: String,
                durationLabel: String = "", rangeStart: String? = nil, rangeEnd: String? = nil) {
        self.id = id; self.kind = kind; self.status = status; self.days = days
        self.dates = dates; self.periodLabel = periodLabel
        self.durationLabel = durationLabel; self.rangeStart = rangeStart; self.rangeEnd = rangeEnd
    }
}

public struct PluginCalendarEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let calendarID: String
    public let title: String
    public let start: Date
    /// nil when the page does not expose a trustworthy end time.
    public let end: Date?
    public let isAllDay: Bool
    public init(id: String, calendarID: String, title: String, start: Date, end: Date? = nil, isAllDay: Bool) {
        self.id = id; self.calendarID = calendarID; self.title = title
        self.start = start; self.end = end; self.isAllDay = isAllDay
    }
}

public struct PluginCoverage: Codable, Sendable, Equatable {
    public let calendarFrom: String?
    public let calendarThrough: String?
    public let leaveHistoryIsLimited: Bool
    public let leaveYear: Int?
    public init(calendarFrom: String? = nil, calendarThrough: String? = nil,
                leaveHistoryIsLimited: Bool = true, leaveYear: Int? = nil) {
        self.calendarFrom = calendarFrom; self.calendarThrough = calendarThrough
        self.leaveHistoryIsLimited = leaveHistoryIsLimited
        self.leaveYear = leaveYear
    }
}

public struct PluginSnapshot: Codable, Sendable, Equatable {
    public let pluginID: String
    public let fetchedAt: Date
    public let leave: PluginLeaveBalance?
    public let vacations: [PluginVacation]
    public let events: [PluginCalendarEvent]
    public let coverage: PluginCoverage
    public init(pluginID: String, fetchedAt: Date, leave: PluginLeaveBalance?, vacations: [PluginVacation],
                events: [PluginCalendarEvent], coverage: PluginCoverage) {
        self.pluginID = pluginID; self.fetchedAt = fetchedAt; self.leave = leave
        self.vacations = vacations; self.events = events; self.coverage = coverage
    }
}

/// In-process extension point. Implementations own their authentication and background session.
@MainActor
public protocol AppPlugin: AnyObject {
    var descriptor: PluginDescriptor { get }
    func refresh() async throws -> PluginSnapshot
    func cancel()
}

/// Consumer API deliberately contains no credentials or browser session objects.
@MainActor
public protocol PluginDataProviding {
    func snapshot(for pluginID: String) -> PluginSnapshot?
    func vacations(for pluginID: String) -> [PluginVacation]
    func calendarEvents(for pluginID: String, startingIn range: DateInterval) -> [PluginCalendarEvent]
}

@MainActor
public final class PluginRegistry: PluginDataProviding {
    private var plugins: [String: any AppPlugin] = [:]
    private var enabled: Set<String> = []
    private var generations: [String: Int] = [:]
    private var running: [String: Int] = [:]
    private var snapshots: [String: PluginSnapshot] = [:]
    public init() {}

    public var descriptors: [PluginDescriptor] {
        plugins.values.map(\.descriptor).sorted { $0.id < $1.id }
    }
    public func isEnabled(_ id: String) -> Bool { enabled.contains(id) }
    public func unregister(_ id: String) {
        deactivate(id); plugins[id] = nil
    }

    public func register(_ plugin: any AppPlugin) throws {
        guard plugins[plugin.descriptor.id] == nil else { throw PluginFailure.duplicatePlugin }
        plugins[plugin.descriptor.id] = plugin
    }

    public func activate(_ id: String) throws {
        guard plugins[id] != nil else { throw PluginFailure.unavailable }
        enabled.insert(id)
    }

    public func deactivate(_ id: String) {
        enabled.remove(id)
        generations[id, default: 0] += 1
        plugins[id]?.cancel()
        running[id] = nil
        snapshots[id] = nil
    }

    @discardableResult
    public func refresh(_ id: String) async throws -> PluginSnapshot {
        guard enabled.contains(id), let plugin = plugins[id] else { throw PluginFailure.disabled }
        guard running[id] == nil else { throw PluginFailure.busy }
        let generation = generations[id, default: 0]
        running[id] = generation
        defer { if running[id] == generation { running[id] = nil } }
        let value = try await plugin.refresh()
        try Task.checkCancellation()
        guard enabled.contains(id), generations[id, default: 0] == generation else { throw CancellationError() }
        guard value.pluginID == id else { throw PluginFailure.unsupportedResponse }
        snapshots[id] = value
        return value
    }

    public func snapshot(for pluginID: String) -> PluginSnapshot? {
        enabled.contains(pluginID) ? snapshots[pluginID] : nil
    }
    public func vacations(for pluginID: String) -> [PluginVacation] { snapshot(for: pluginID)?.vacations ?? [] }
    public func calendarEvents(for pluginID: String, startingIn range: DateInterval) -> [PluginCalendarEvent] {
        (snapshot(for: pluginID)?.events ?? []).filter { $0.start >= range.start && $0.start < range.end }
    }
}
