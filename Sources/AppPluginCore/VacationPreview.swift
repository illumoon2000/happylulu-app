import Foundation

extension PluginSnapshot {
    /// Confirms an explicitly approved full day using source civil dates and a snapshot at most 15 minutes old.
    public func hasConfirmedFullDayLeave(on day: Date, timeZone: TimeZone, now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        guard fetchedAt.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite,
              day.timeIntervalSince1970.isFinite, age.isFinite, age >= 0, age <= 15 * 60 else { return false }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let target = formatter.string(from: day)
        // Validate civil dates independently of DST or midnight transitions in the source zone.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        func isStrictDay(_ value: String) -> Bool {
            guard value.count == 10, let date = formatter.date(from: value) else { return false }
            return formatter.string(from: date) == value
        }

        return vacations.contains { vacation in
            guard vacation.status.trimmingCharacters(in: .whitespacesAndNewlines) == "APPROVAL",
                  ["연차", "공가", "연차/공가"].contains(vacation.kind.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let days = vacation.days, days.isFinite else { return false }
            if !vacation.dates.isEmpty {
                guard vacation.rangeStart == nil, vacation.rangeEnd == nil,
                      Set(vacation.dates).count == vacation.dates.count,
                      days == Double(vacation.dates.count), vacation.dates.allSatisfy(isStrictDay) else { return false }
                return vacation.dates.contains(target)
            }
            // Multi-day ranges do not identify which dates received a full day of leave.
            guard days == 1, let start = vacation.rangeStart, let end = vacation.rangeEnd,
                  start == end, start == target, isStrictDay(start) else { return false }
            return true
        }
    }
}
