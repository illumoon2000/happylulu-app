import Foundation
import CryptoKit
import AppPluginCore

/// The Daouoffice 4 frontend response contract, verified against its public service modules.
/// A missing field fails the refresh; it never replaces a last good snapshot with empty data.
public enum DaouOfficeAPIParser {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 8 * 1_024 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginFailure.unsupportedResponse
        }
        return object
    }
    public static func payload(_ data: Data) throws -> Any {
        let root = try object(data)
        if let code = root["code"], String(describing: code) != "200" { throw PluginFailure.unsupportedResponse }
        guard let payload = root["data"], !(payload is NSNull) else { throw PluginFailure.unsupportedResponse }
        return payload
    }
    public static func elements(_ data: Data) throws -> [[String: Any]] {
        guard let payload = try payload(data) as? [String: Any],
              let items = payload["elements"] as? [[String: Any]] else { throw PluginFailure.unsupportedResponse }
        return items
    }
    public static func identifier(_ value: Any?) throws -> String {
        if let string = value as? String, !string.isEmpty, string.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "_" || $0 == "-") }) {
            return string
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0 {
            // NSNumber.stringValue preserves server Int64 IDs; converting through Double loses precision.
            let id = number.stringValue
            if id.allSatisfy({ $0.isASCII && $0.isNumber }) { return id }
        }
        throw PluginFailure.unsupportedResponse
    }
    public static func date(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            throw PluginFailure.unsupportedResponse
        }
        return date
    }
    public static func localDay(_ value: String) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw PluginFailure.unsupportedResponse
        }
        return value
    }
    private static func number(_ value: Any?) throws -> Double {
        if let string = value as? String,
           string.range(of: #"^-?\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
           let number = Double(string), number.isFinite {
            return number
        }
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw PluginFailure.unsupportedResponse
        }
        return value.doubleValue
    }
    private static func days(_ value: String) -> Double? {
        guard let match = value.range(of: #"^-?\d+(?:\.\d+)?(?=d(?:\s|\(|$))"#, options: .regularExpression) else { return nil }
        return Double(value[match])
    }
    public static func balance(_ data: Data) throws -> PluginLeaveBalance {
        guard let value = try payload(data) as? [String: Any], let remain = value["formattedRemain"] as? String,
              let remaining = days(remain) else { throw PluginFailure.unsupportedResponse }
        let total = try number(value["totalDays"]), used = try number(value["usedDays"])
        guard total >= 0, used >= 0 else { throw PluginFailure.unsupportedResponse }
        return PluginLeaveBalance(totalDays: total, usedDays: used, remainingDays: remaining)
    }
    public static func vacations(_ data: Data) throws -> [PluginVacation] {
        try elements(data).map { value in
            guard let kind = value["title"] as? String, !kind.isEmpty,
                  let status = value["approvalStatusType"] as? String,
                  let duration = value["formattedUsedDuration"] as? String,
                  let rangeType = value["dateRangeType"] as? String else { throw PluginFailure.unsupportedResponse }
            var dates: [String] = [], start: String?, end: String?
            if rangeType == "PERIOD_SPECIFICATION" {
                guard let first = value["startDate"] as? String, let last = value["endDate"] as? String else { throw PluginFailure.unsupportedResponse }
                start = try localDay(first); end = try localDay(last)
                guard first <= last else { throw PluginFailure.unsupportedResponse }
            } else if rangeType == "DATE_SELECTION" {
                guard let entries = value["dateList"] as? [[String: Any]], !entries.isEmpty else { throw PluginFailure.unsupportedResponse }
                dates = try entries.map { item in
                    guard let date = item["date"] as? String else { throw PluginFailure.unsupportedResponse }
                    return try localDay(date)
                }
            } else { throw PluginFailure.unsupportedResponse }
            let period = start.map { "\($0) ~ \(end!)" } ?? dates.joined(separator: ", ")
            let identity = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            let id = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            return PluginVacation(id: id, kind: kind, status: status, days: days(duration), dates: dates,
                periodLabel: period, durationLabel: duration, rangeStart: start, rangeEnd: end)
        }
    }
    /// Publish only occurrences overlapping the requested half-open interval.
    /// The service also returns out-of-range lunar holiday reference dates (including 1970).
    public static func events(_ data: Data, during interval: DateInterval) throws -> [PluginCalendarEvent] {
        guard let values = try payload(data) as? [[String: Any]] else { throw PluginFailure.unsupportedResponse }
        var seen = Set<String>()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return try values.map { value in
            let sourceID = try identifier(value["id"]), calendarID = try identifier(value["calendarId"])
            guard let title = value["summary"] as? String, let first = value["startTime"] as? String,
                  let last = value["endTime"] as? String, let type = value["timeType"] as? String,
                  ["allday", "timed"].contains(type) else { throw PluginFailure.unsupportedResponse }
            let start = try date(first), end = try date(last)
            guard end >= start else { throw PluginFailure.unsupportedResponse }
            // Include start even when a service returns the series ID for every occurrence.
            return PluginCalendarEvent(id: "\(calendarID):\(sourceID):\(first)", calendarID: calendarID,
                title: title, start: start, end: end, isAllDay: type == "allday")
        }.filter { event in
            guard var end = event.end else { return false }
            if event.isAllDay {
                // Match the adapter's inclusive final day without changing the stored source bounds.
                guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) else { return false }
                end = next
            }
            let overlaps = end == event.start
                ? event.start >= interval.start && event.start < interval.end
                : event.start < interval.end && end > interval.start
            return overlaps && seen.insert(event.id).inserted
        }.sorted { $0.start < $1.start }
    }
}
