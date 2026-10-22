import Foundation

public struct UsageRate: Equatable, Sendable {
    public let consumedPercentagePoints: Double
    public let observedSeconds: TimeInterval

    public var perHour: Double { consumedPercentagePoints / (observedSeconds / 3600) }
    public var observedMinutes: Double { observedSeconds / 60 }
}

public struct UsageAnalysis: Equatable, Sendable {
    public let hour: UsageRate?
}

/// Rates describe observed changes in weekly quota, not tokens or requests.
/// Keep one continuous series per account and weekly reset boundary.
public struct UsageHistory: Codable, Sendable {
    private struct Sample: Codable, Sendable {
        let date: Date
        let usedPercent: Double
        let cadenceMinutes: Int
    }

    private var accountKey: String?
    private var resetsAt: Double?
    private var samples: [Sample] = []

    public init() {}
    public var sampleCount: Int { samples.count }
    public var canPersist: Bool { accountKey != nil && resetsAt != nil }

    public mutating func clear() {
        accountKey = nil
        resetsAt = nil
        samples = []
    }

    public mutating func record(_ snapshot: UsageSnapshot, cadenceMinutes: Int) {
        let window = snapshot.weekly
        guard window.usedPercent.isFinite, snapshot.fetchedAt.timeIntervalSince1970.isFinite,
              let reset = window.resetsAt, reset.isFinite,
              reset > snapshot.fetchedAt.timeIntervalSince1970 else {
            clear()
            return
        }

        if accountKey != snapshot.accountKey || resetsAt != reset {
            clear()
            accountKey = snapshot.accountKey
            resetsAt = reset
        }
        let cadence = max(1, min(30, cadenceMinutes))
        let used = min(100, max(0, window.usedPercent))
        if let previous = samples.last {
            let elapsed = snapshot.fetchedAt.timeIntervalSince(previous.date)
            guard elapsed > 0 else { return } // Ignore duplicate and out-of-order observations.
            let maximumGap = Double(max(cadence, previous.cadenceMinutes)) * 60 * 1.5 + 30
            // A drop may be a reset, account/workspace change, or server correction.
            // Never turn it into negative consumption or join across an unobserved gap.
            if used < previous.usedPercent || elapsed > maximumGap { samples = [] }
        }
        samples.append(Sample(date: snapshot.fetchedAt, usedPercent: used, cadenceMinutes: cadence))
        let cutoff = snapshot.fetchedAt.addingTimeInterval(-2 * 3600)
        samples.removeAll { $0.date < cutoff }
        if samples.count > 1440 { samples.removeFirst(samples.count - 1440) }
    }

    public func analysis(at date: Date = Date()) -> UsageAnalysis {
        guard let reset = resetsAt, reset > date.timeIntervalSince1970,
              let last = samples.last, last.date <= date else {
            return UsageAnalysis(hour: nil)
        }
        // Use actual observations inside the last hour; never interpolate a missing boundary.
        let hourStart = samples.first { last.date.timeIntervalSince($0.date) <= 3600 }
        func rate(from start: Sample?) -> UsageRate? {
            guard let start else { return nil }
            let elapsed = last.date.timeIntervalSince(start.date)
            guard elapsed >= 60 else { return nil }
            return UsageRate(consumedPercentagePoints: max(0, last.usedPercent - start.usedPercent),
                             observedSeconds: elapsed)
        }
        return UsageAnalysis(hour: rate(from: hourStart))
    }

    private enum CodingKeys: String, CodingKey { case accountKey, resetsAt, samples }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey)
        resetsAt = try container.decodeIfPresent(Double.self, forKey: .resetsAt)
        samples = try container.decode([Sample].self, forKey: .samples)
        guard let reset = resetsAt, reset.isFinite, samples.count <= 1440,
              samples.allSatisfy({ $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
                && $0.date.timeIntervalSince1970.isFinite && $0.date.timeIntervalSince1970 < reset
                && (1...30).contains($0.cadenceMinutes) }) else {
            clear()
            return
        }
        for (previous, next) in zip(samples, samples.dropFirst()) {
            let elapsed = next.date.timeIntervalSince(previous.date)
            let maxGap = Double(max(previous.cadenceMinutes, next.cadenceMinutes)) * 90 + 30
            if elapsed <= 0 || elapsed > maxGap || next.usedPercent < previous.usedPercent {
                clear()
                return
            }
        }
    }
}
