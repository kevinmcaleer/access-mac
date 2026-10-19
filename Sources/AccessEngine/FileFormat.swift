/// The on-disk format generations Access has used.
public enum FileFormat: String, Sendable, CaseIterable {
    /// Jet 3: Access 97.
    case jet3
    /// Jet 4: Access 2000, 2002 and 2003 `.mdb`.
    case jet4
    /// ACE 12: Access 2007 `.accdb`.
    case ace12
    /// ACE 14: Access 2010 `.accdb`.
    case ace14
    /// ACE 15: Access 2013 `.accdb`.
    case ace15
    /// ACE 16: Access 2016 and later `.accdb`.
    case ace16
    /// ACE 17: Access 2019 / Microsoft 365 `.accdb`.
    case ace17

    init(versionByte: UInt8) throws {
        switch versionByte {
        case 0x00: self = .jet3
        case 0x01: self = .jet4
        case 0x02: self = .ace12
        case 0x03: self = .ace14
        case 0x04: self = .ace15
        case 0x05: self = .ace16
        case 0x06: self = .ace17
        default: throw EngineError.unsupportedVersion(versionByte)
        }
    }

    public var isJet3: Bool { self == .jet3 }
    public var isACE: Bool { !(self == .jet3 || self == .jet4) }

    /// The Access release that writes this format by default.
    public var displayName: String {
        switch self {
        case .jet3: return "Access 97 (Jet 3)"
        case .jet4: return "Access 2000-2003 (Jet 4)"
        case .ace12: return "Access 2007 (ACE 12)"
        case .ace14: return "Access 2010 (ACE 14)"
        case .ace15: return "Access 2013 (ACE 15)"
        case .ace16: return "Access 2016 (ACE 16)"
        case .ace17: return "Access 2019 / 365 (ACE 17)"
        }
    }

    public var fileExtension: String { isACE ? "accdb" : "mdb" }

    var layout: Layout { isJet3 ? .jet3 : .jet4 }
}

/// Byte offsets and sizes that differ between Jet 3 and Jet 4/ACE.
struct Layout {
    let pageSize: Int
    let headerEncryptedLength: Int

    // Data pages
    let dataRowCountOffset: Int

    // Table definition (TDEF) block
    let tdefNumRowsOffset: Int
    let tdefTableTypeOffset: Int
    let tdefMaxColsOffset: Int
    let tdefNumVarColsOffset: Int
    let tdefNumColsOffset: Int
    let tdefNumIndexesOffset: Int
    let tdefNumRealIndexesOffset: Int
    let tdefUsageMapOffset: Int
    let tdefFreeMapOffset: Int
    let tdefColumnsStart: Int
    let realIndexEntrySize: Int

    // Column entries in the TDEF
    let columnEntrySize: Int
    let colNumberOffset: Int
    let colVarIndexOffset: Int
    let colFlagsOffset: Int
    let colExtFlagsOffset: Int?
    let colFixedOffsetOffset: Int
    let colLengthOffset: Int
    let colPrecisionOffset: Int
    let colScaleOffset: Int

    // Index definitions
    let realIndexDefSize: Int
    let realIndexDefLeadIn: Int
    let logicalIndexSize: Int
    let logicalIndexLeadIn: Int

    // Rows
    let rowColumnCountSize: Int

    static let jet3 = Layout(
        pageSize: 2048, headerEncryptedLength: 126,
        dataRowCountOffset: 0x08,
        tdefNumRowsOffset: 12, tdefTableTypeOffset: 20, tdefMaxColsOffset: 21, tdefNumVarColsOffset: 23,
        tdefNumColsOffset: 25, tdefNumIndexesOffset: 27, tdefNumRealIndexesOffset: 31,
        tdefUsageMapOffset: 35, tdefFreeMapOffset: 39, tdefColumnsStart: 43, realIndexEntrySize: 8,
        columnEntrySize: 18, colNumberOffset: 1, colVarIndexOffset: 3, colFlagsOffset: 13,
        colExtFlagsOffset: nil, colFixedOffsetOffset: 14, colLengthOffset: 16,
        colPrecisionOffset: 11, colScaleOffset: 12,
        realIndexDefSize: 39, realIndexDefLeadIn: 0, logicalIndexSize: 20, logicalIndexLeadIn: 0,
        rowColumnCountSize: 1)

    static let jet4 = Layout(
        pageSize: 4096, headerEncryptedLength: 128,
        dataRowCountOffset: 0x0C,
        tdefNumRowsOffset: 16, tdefTableTypeOffset: 40, tdefMaxColsOffset: 41, tdefNumVarColsOffset: 43,
        tdefNumColsOffset: 45, tdefNumIndexesOffset: 47, tdefNumRealIndexesOffset: 51,
        tdefUsageMapOffset: 55, tdefFreeMapOffset: 59, tdefColumnsStart: 63, realIndexEntrySize: 12,
        columnEntrySize: 25, colNumberOffset: 5, colVarIndexOffset: 7, colFlagsOffset: 15,
        colExtFlagsOffset: 16, colFixedOffsetOffset: 21, colLengthOffset: 23,
        colPrecisionOffset: 11, colScaleOffset: 12,
        realIndexDefSize: 52, realIndexDefLeadIn: 4, logicalIndexSize: 28, logicalIndexLeadIn: 4,
        rowColumnCountSize: 2)
}

/// Page types, stored in the first byte of every page.
enum PageType: UInt8 {
    case header = 0x00
    case data = 0x01
    case tableDefinition = 0x02
    case indexIntermediate = 0x03
    case indexLeaf = 0x04
    case usageMap = 0x05
}
