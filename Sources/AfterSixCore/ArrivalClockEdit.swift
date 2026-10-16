import Foundation

/// An unsaved HH:mm draft; a new default is a real edit even before any digit changes.
public struct ArrivalClockEdit: Equatable {
    public private(set) var digits: [String]
    private let originalText: String?

    public init(existingTime: Date?, now: Date, timeZone: TimeZone) {
        originalText = existingTime.map { Attendance.clockLabel($0, timeZone: timeZone) }
        digits = (originalText ?? Attendance.clockLabel(now, timeZone: timeZone))
            .filter { $0 != ":" }.map(String.init)
    }

    public var text: String { digits[0] + digits[1] + ":" + digits[2] + digits[3] }
    public var needsSave: Bool { originalText != text }

    public mutating func replaceDigit(at index: Int, with input: String) {
        guard digits.indices.contains(index) else { return }
        let pasted = input.filter { $0 != ":" }
        if pasted.count == 4 && pasted.allSatisfy({ $0.isASCII && $0.isNumber }) {
            digits = pasted.map(String.init)
        } else if input.isEmpty {
            digits[index] = ""
        } else if input.count == 2, !digits[index].isEmpty, input.hasSuffix(digits[index]),
                  let first = input.first, first.isASCII && first.isNumber {
            digits[index] = String(first)
        } else if let last = input.last, last.isASCII && last.isNumber {
            digits[index] = String(last)
        }
    }

    /// No carry or wrap: changing a digit must leave a valid 24-hour clock.
    @discardableResult public mutating func adjustDigit(at index: Int, by delta: Int) -> Bool {
        guard digits.indices.contains(index), (-1...1).contains(delta),
              digits.allSatisfy({ $0.count == 1 }), let digit = Int(digits[index]),
              (0...9).contains(digit + delta) else { return false }
        var candidate = digits
        candidate[index] = String(digit + delta)
        guard let hour = Int(candidate[0] + candidate[1]), hour < 24,
              let minute = Int(candidate[2] + candidate[3]), minute < 60 else { return false }
        digits = candidate
        return true
    }

    public func canAdjustDigit(at index: Int, by delta: Int) -> Bool {
        var candidate = self
        return candidate.adjustDigit(at: index, by: delta)
    }
}
