import Darwin
import Foundation

public struct CPUUsageTicks: Equatable, Sendable {
    public let user: UInt64
    public let system: UInt64
    public let nice: UInt64
    public let idle: UInt64

    public init(user: UInt64, system: UInt64, nice: UInt64, idle: UInt64) {
        self.user = user; self.system = system; self.nice = nice; self.idle = idle
    }
}

@MainActor
public final class CPUUsageSampler {
    private let readTicks: () -> CPUUsageTicks?
    private var previous: CPUUsageTicks?

    public init(readTicks: @escaping () -> CPUUsageTicks? = CPUUsageSampler.systemTicks) {
        self.readTicks = readTicks
    }

    public func reset() { previous = nil }

    public func sample() -> Double? {
        guard let current = readTicks() else { previous = nil; return nil }
        defer { previous = current }
        guard let previous,
              current.user >= previous.user, current.system >= previous.system,
              current.nice >= previous.nice, current.idle >= previous.idle else { return nil }
        let busy = Double(current.user - previous.user) + Double(current.system - previous.system)
            + Double(current.nice - previous.nice)
        let total = busy + Double(current.idle - previous.idle)
        return total > 0 ? busy / total : nil
    }

    nonisolated public static func systemTicks() -> CPUUsageTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUUsageTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
            nice: UInt64(info.cpu_ticks.3), idle: UInt64(info.cpu_ticks.2))
    }
}

public enum RunnerAnimationPolicy {
    public static func frameInterval(usage: Double?, reduceMotion: Bool, lowPower: Bool) -> TimeInterval? {
        guard !reduceMotion, let usage, usage.isFinite, (0...1).contains(usage) else { return nil }
        let framesPerSecond = min(lowPower ? 4 : 16, 2 + usage * 14)
        return 1 / framesPerSecond
    }
}
