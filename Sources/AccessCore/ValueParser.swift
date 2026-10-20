import AccessEngine
import Foundation

/// A value typed into a datasheet cell that doesn't fit the field.
public struct ValueEntryError: Error, Equatable, CustomStringConvertible {
    public let field: String
    public let expected: String

    public var description: String {
        "The value you entered isn't valid for \(field). It needs \(expected)."
    }
}

/// Turns text typed into a cell into a value for the cell's column, as an
/// Access datasheet does.
public enum ValueParser {
    /// Whether values of this column can be typed as text.
    public static func isTypeable(_ column: Column) -> Bool {
        switch column.type {
        case .binary, .ole, .complex, .unknown0D, .unknown11, .extendedDateTime: return false
        default: return !column.isAutoNumber
        }
    }

    /// The text a cell shows while it's being edited.
    public static func editingText(_ value: Value) -> String {
        switch value {
        case .currency(let d), .decimal(let d): return "\(d)"
        default: return value.displayString
        }
    }

    public static func parse(_ text: String, for column: Column) throws -> Value {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func fail(_ expected: String) -> ValueEntryError { ValueEntryError(field: column.name, expected: expected) }
        if column.type == .boolean {
            switch trimmed.lowercased() {
            case "", "no", "false", "off", "0": return .boolean(false)
            case "yes", "true", "on", "-1", "1": return .boolean(true)
            default: throw fail("Yes or No")
            }
        }
        if trimmed.isEmpty { return .null }
        let number = trimmed.replacingOccurrences(of: ",", with: "")

        switch column.type {
        case .text, .memo:
            return .text(text)
        case .byte:
            guard let v = UInt8(number) else { throw fail("a whole number from 0 to 255") }
            return .byte(v)
        case .integer:
            guard let v = Int16(number) else { throw fail("a whole number from -32,768 to 32,767") }
            return .integer(v)
        case .long:
            guard let v = Int32(number) else { throw fail("a whole number from -2,147,483,648 to 2,147,483,647") }
            return .long(v)
        case .bigInt:
            guard let v = Int64(number) else { throw fail("a whole number") }
            return .bigInt(v)
        case .single:
            guard let v = Float(number), v.isFinite else { throw fail("a number") }
            return .single(v)
        case .double:
            guard let v = Double(number), v.isFinite else { throw fail("a number") }
            return .double(v)
        case .currency:
            var amount = number.replacingOccurrences(of: "$", with: "")
            var negative = false
            if amount.hasPrefix("("), amount.hasSuffix(")") {
                negative = true
                amount = String(amount.dropFirst().dropLast())
            }
            guard let v = decimal(amount) else { throw fail("a currency amount") }
            return .currency(negative ? -v : v)
        case .numeric:
            guard let v = decimal(number) else { throw fail("a number") }
            return .decimal(v)
        case .dateTime:
            guard let date = parseDate(trimmed) else { throw fail("a date or time, such as 2024-03-15 or 3/15/2024 2:30 PM") }
            return .dateTime(date)
        case .guid:
            let hex = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).uppercased()
            let groups = hex.split(separator: "-", omittingEmptySubsequences: false)
            guard groups.map(\.count) == [8, 4, 4, 4, 12], groups.allSatisfy({ $0.allSatisfy(\.isHexDigit) }) else {
                throw fail("a Replication ID such as {12345678-1234-1234-1234-123456789ABC}")
            }
            return .guid("{" + hex + "}")
        default:
            throw fail("a value that can't be typed")
        }
    }

    private static func decimal(_ text: String) -> Decimal? {
        guard text.range(of: #"^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Dates as yyyy-mm-dd or m/d/yyyy, optionally followed by a time
    /// (h:mm, h:mm:ss, with AM/PM or 24-hour), or a time alone.
    static func parseDate(_ text: String) -> AccessDate? {
        let pattern = #"^(?:(\d{4})-(\d{1,2})-(\d{1,2})|(\d{1,2})/(\d{1,2})/(\d{2,4}))?\s*(?:(?:T|\s)?(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> Int? {
            guard let range = Range(match.range(at: i), in: text) else { return nil }
            return Int(text[range])
        }
        var year = 1899, month = 12, day = 30
        if let y = group(1), let m = group(2), let d = group(3) {
            (year, month, day) = (y, m, d)
        } else if let m = group(4), let d = group(5), var y = group(6) {
            if y < 100 { y += y < 30 ? 2000 : 1900 }
            (year, month, day) = (y, m, d)
        } else if group(7) == nil {
            return nil
        }
        var hour = group(7) ?? 0
        let minute = group(8) ?? 0, second = group(9) ?? 0
        if let range = Range(match.range(at: 10), in: text) {
            let pm = text[range].lowercased() == "pm"
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (pm ? 12 : 0)
        }
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...59).contains(second), (100...9999).contains(year) else { return nil }
        let date = AccessDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        // Reject dates like February 30 that roll over.
        let c = date.components
        guard c.year == year, c.month == month, c.day == day else { return nil }
        return date
    }
}
