import Foundation

/// A field value read from a row.
public enum Value: Hashable, Sendable {
    case null
    case boolean(Bool)
    case byte(UInt8)
    case integer(Int16)
    case long(Int32)
    case bigInt(Int64)
    case single(Float)
    case double(Double)
    case currency(Decimal)
    case decimal(Decimal)
    case dateTime(AccessDate)
    /// Date/Time Extended, kept as the text Access stores.
    case extendedDateTime(String)
    case text(String)
    case binary([UInt8])
    case guid(String)
    /// The key of a row in a complex column's hidden table.
    case complex(Int32)

    public var isNull: Bool { self == .null }

    /// The value formatted the way an Access datasheet shows it by default.
    public var displayString: String {
        switch self {
        case .null: return ""
        case .boolean(let b): return b ? "Yes" : "No"
        case .byte(let v): return String(v)
        case .integer(let v): return String(v)
        case .long(let v): return String(v)
        case .bigInt(let v): return String(v)
        case .single(let v): return Self.trimmedNumber(Double(v), digits: 7)
        case .double(let v): return Self.trimmedNumber(v, digits: 15)
        case .currency(let v): return Self.currencyFormatter.string(from: v as NSDecimalNumber) ?? "\(v)"
        case .decimal(let v): return "\(v)"
        case .dateTime(let d): return d.description
        case .extendedDateTime(let s): return s
        case .text(let s): return s
        case .binary(let b): return b.isEmpty ? "" : "Binary data (\(b.count) bytes)"
        case .guid(let g): return g
        case .complex(let id): return "Complex value #\(id)"
        }
    }

    private static func trimmedNumber(_ value: Double, digits: Int) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let s = String(format: "%.\(digits)g", value)
        return s
    }

    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        return f
    }()
}

/// An Access Date/Time: days since 30 December 1899 with the time of day as
/// the fraction. Before 1899 the integer part is negative but the fraction
/// still counts forward from midnight.
public struct AccessDate: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Double

    public init(rawValue: Double) { self.rawValue = rawValue }

    /// The date and time given by calendar fields (proleptic Gregorian).
    public init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        // Days-from-civil (Howard Hinnant), shifted so 1899-12-30 is day 0.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468 + 25_569
        let fraction = Double(hour * 3600 + minute * 60 + second) / 86_400
        // Before 1899 the whole part is negative but the time still counts
        // forward.
        rawValue = days < 0 ? Double(days) - fraction : Double(days) + fraction
    }

    public struct Components: Equatable, Sendable {
        public var year, month, day, hour, minute, second, millisecond: Int
    }

    public var components: Components {
        var days = rawValue.rounded(.towardZero)
        var millis = (abs(rawValue - days) * 86_400_000).rounded()
        if millis >= 86_400_000 {
            millis -= 86_400_000
            days += rawValue < 0 ? -1 : 1
        }
        // Civil-from-days (Howard Hinnant), with day 0 = 1899-12-30.
        let z = Int(days) - 25_569 + 719_468   // 1899-12-30 is 25569 days before 1970-01-01
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        let ms = Int(millis)
        return Components(year: year, month: month, day: day,
                          hour: ms / 3_600_000, minute: ms / 60_000 % 60,
                          second: ms / 1000 % 60, millisecond: ms % 1000)
    }

    /// The value as a `Date`, treating the stored wall-clock time as UTC.
    public var date: Date {
        Date(timeIntervalSince1970: 0).addingTimeInterval(
            (rawValue.rounded(.towardZero) - 25_569) * 86_400
                + abs(rawValue - rawValue.rounded(.towardZero)) * 86_400)
    }

    /// ISO-style `yyyy-MM-dd HH:mm:ss`, omitting the time at midnight.
    public var description: String {
        let c = components
        let date = String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
        if c.hour == 0, c.minute == 0, c.second == 0 { return date }
        return date + String(format: " %02d:%02d:%02d", c.hour, c.minute, c.second)
    }
}
