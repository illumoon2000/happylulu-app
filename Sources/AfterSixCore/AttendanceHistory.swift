import Foundation

extension Attendance {
    /// Stored keys may use an older system calendar; display the recorded local civil day without rewriting them.
    public static func historyDay(for arrival: Arrival) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: arrival.timeZoneID) ?? .current
        return dayKey(arrival.time, calendar: calendar)
    }
}
