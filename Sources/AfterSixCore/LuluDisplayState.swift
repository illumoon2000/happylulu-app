import Foundation

/// Presentation only: consumes existing attendance decisions without changing them.
public enum LuluDisplayState: String, CaseIterable, Sendable {
    case waiting, regular, luluDay, morningHalf, afternoonHalf, readyToLeave, annualLeave, dayOff

    public static func resolve(dayType: ManualDayType, isSkipped: Bool, hasArrival: Bool,
                               departure: Date?, now: Date) -> Self {
        if dayType == .annualLeave { return .annualLeave }
        if isSkipped { return .dayOff }
        guard hasArrival else { return .waiting }
        if let departure, now >= departure { return .readyToLeave }
        switch dayType {
        case .regular: return .regular
        case .luluDay: return .luluDay
        case .morningHalf: return .morningHalf
        case .afternoonHalf: return .afternoonHalf
        case .annualLeave: return .annualLeave
        }
    }
}
