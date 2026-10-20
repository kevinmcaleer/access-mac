/// The column type codes stored in a table definition.
public enum ColumnType: UInt8, Sendable, CaseIterable {
    case boolean = 0x01
    case byte = 0x02
    case integer = 0x03
    case long = 0x04
    case currency = 0x05
    case single = 0x06
    case double = 0x07
    case dateTime = 0x08
    case binary = 0x09
    case text = 0x0A
    case ole = 0x0B
    case memo = 0x0C
    case unknown0D = 0x0D
    case guid = 0x0F
    case numeric = 0x10
    case unknown11 = 0x11
    case complex = 0x12
    case bigInt = 0x13
    case extendedDateTime = 0x14

    /// The name Access shows for the type in Design view.
    public var accessName: String {
        switch self {
        case .boolean: return "Yes/No"
        case .byte: return "Number (Byte)"
        case .integer: return "Number (Integer)"
        case .long: return "Number (Long Integer)"
        case .currency: return "Currency"
        case .single: return "Number (Single)"
        case .double: return "Number (Double)"
        case .dateTime: return "Date/Time"
        case .binary: return "Binary"
        case .text: return "Short Text"
        case .ole: return "OLE Object"
        case .memo: return "Long Text"
        case .guid: return "Number (Replication ID)"
        case .numeric: return "Number (Decimal)"
        case .complex: return "Attachment / Multi-value"
        case .bigInt: return "Large Number"
        case .extendedDateTime: return "Date/Time Extended"
        case .unknown0D, .unknown11: return "Unknown"
        }
    }

    /// Bytes a fixed-length column of this type occupies in a row.
    var fixedSize: Int? {
        switch self {
        case .boolean: return 0
        case .byte: return 1
        case .integer: return 2
        case .long, .single, .complex: return 4
        case .currency, .double, .dateTime, .bigInt: return 8
        case .guid: return 16
        case .numeric: return 17
        case .extendedDateTime: return 42
        default: return nil
        }
    }

    /// Long-value types, whose data lives in LVAL records.
    var isLongValue: Bool { self == .memo || self == .ole }
}

/// A column of a table, as described by its table definition.
public struct Column: Sendable, Hashable {
    public let name: String
    public let type: ColumnType
    /// The column number used by the row null mask; columns are listed in
    /// this order.
    public let number: Int
    /// Index into the row's variable-length column offset table.
    let variableIndex: Int
    /// Offset of the value inside the row's fixed-length data.
    let fixedOffset: Int
    /// Declared length in bytes (Short Text stores two bytes per character).
    public let length: Int
    public let precision: Int
    public let scale: Int
    let flags: UInt8
    let extFlags: UInt8
    /// Text collation: the locale value and, in Jet 4 and later, a version.
    let sortOrder: SortOrder

    public var isFixedLength: Bool { flags & 0x01 != 0 }
    public var isAutoNumber: Bool { flags & 0x04 != 0 || flags & 0x40 != 0 }
    public var isHyperlink: Bool { flags & 0x80 != 0 && type == .memo }
    public var isCompressedUnicode: Bool { extFlags & 0x01 != 0 }
    public var isCalculated: Bool { extFlags & 0xC0 != 0 }

    /// Declared size in characters for Short Text, bytes for other types.
    public var size: Int { type == .text ? length / 2 : length }
}

/// The collating order of a text column, which decides how its index keys
/// are encoded.
struct SortOrder: Hashable, Sendable {
    var value: UInt16
    var version: UInt8

    /// "General" in Access 2010 and later.
    static let general = SortOrder(value: 1033, version: 1)
    /// "General - Legacy", the default for Jet 4 and Access 2007.
    static let generalLegacy = SortOrder(value: 1033, version: 0)
}

/// An index: a logical index as Access shows it, backed by a physical one.
public struct Index: Sendable, Hashable {
    public enum Kind: Sendable { case normal, primaryKey, foreignKey }
    public let name: String
    public let kind: Kind
    /// Column numbers in key order, with whether each sorts ascending.
    public let columns: [(number: Int, ascending: Bool)]
    public let isUnique: Bool
    public let ignoresNulls: Bool
    public let isRequired: Bool
    /// The physical index's root page and its number in the definition.
    let rootPage: UInt32
    let physicalIndex: Int
    /// The usage map of the index's pages, and its raw flag byte.
    let pagesMap: RowPointer
    let flags: UInt8

    public static func == (lhs: Index, rhs: Index) -> Bool {
        lhs.name == rhs.name && lhs.kind == rhs.kind
            && lhs.columns.map(\.number) == rhs.columns.map(\.number)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(columns.map(\.number))
    }
}
