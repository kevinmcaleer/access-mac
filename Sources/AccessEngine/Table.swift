import Foundation

/// A table in an open database. Rows are located once, cheaply, and decoded
/// on demand so a datasheet can page through large tables.
public final class Table {
    public let name: String
    public let columns: [Column]
    public let indexes: [Index]
    /// The row count recorded in the table definition.
    public let declaredRowCount: Int
    let definition: TableDefinition
    private unowned let database: Database
    private var cachedLocations: [RowPointer]?

    init(name: String, definition: TableDefinition, database: Database) {
        self.name = name
        self.definition = definition
        self.columns = definition.columns
        self.indexes = definition.indexes
        self.declaredRowCount = definition.rowCount
        self.database = database
    }

    public var primaryKey: Index? { indexes.first { $0.kind == .primaryKey } }

    /// The location of every live row, in storage order.
    public func rowLocations() throws -> [RowPointer] {
        if let cachedLocations { return cachedLocations }
        let source = database.source
        var pages: [UInt32]
        do {
            pages = try UsageMap.pages(at: definition.usageMap, source: source)
        } catch {
            pages = []
        }
        if pages.isEmpty { pages = Array(1..<source.pageCount) }
        var locations: [RowPointer] = []
        locations.reserveCapacity(definition.rowCount)
        for number in pages where number < source.pageCount {
            let page = try source.page(number)
            // Pages in the map that hold another table's rows, long values or
            // anything else are skipped.
            guard page[0] == PageType.data.rawValue, page.u32(4) == definition.page else { continue }
            for row in 0..<source.rowCount(onDataPage: page) {
                let bounds = source.rowBounds(page, row: row)
                if bounds.deleted { continue }
                locations.append(RowPointer(page: number, row: UInt8(row)))
            }
        }
        cachedLocations = locations
        return locations
    }

    /// Decodes the row at `location` into one value per column.
    public func row(at location: RowPointer) throws -> [Value] {
        let source = database.source
        var (bytes, _, overflow) = try source.row(at: location)
        var hops = 0
        while overflow {
            guard bytes.count >= 4, hops < 16 else { throw EngineError.corruptRow("bad overflow pointer") }
            (bytes, _, overflow) = try source.row(at: RowPointer(raw: bytes.u32(0)))
            hops += 1
        }
        return try RowDecoder(database: database, definition: definition).decode(bytes)
    }

    /// Every live row, decoded.
    public func allRows() throws -> [[Value]] {
        try rowLocations().map { try row(at: $0) }
    }
}

/// Splits a raw row into column values.
struct RowDecoder {
    let database: Database
    let definition: TableDefinition

    func decode(_ row: [UInt8]) throws -> [Value] {
        let layout = database.source.layout
        let jet3 = database.format.isJet3
        guard row.count >= layout.rowColumnCountSize else { throw EngineError.corruptRow("empty row") }
        let rowColumns = jet3 ? Int(row[0]) : Int(row.u16(0))
        let maskSize = (rowColumns + 7) / 8
        let end = row.count - 1
        guard row.count >= layout.rowColumnCountSize + maskSize else {
            throw EngineError.corruptRow("row shorter than its null mask")
        }
        let maskStart = row.count - maskSize

        var varOffsets: [Int] = []
        var rowVarColumns = 0
        if definition.numVarColumns > 0 {
            if jet3 {
                rowVarColumns = Int(row[end - maskSize])
                varOffsets = jet3VariableOffsets(row, maskSize: maskSize, varColumns: rowVarColumns)
            } else {
                rowVarColumns = Int(row.u16(end - maskSize - 1))
                for i in 0...rowVarColumns {
                    let p = end - maskSize - 3 - i * 2
                    guard p >= 0 else { throw EngineError.corruptRow("variable column table") }
                    varOffsets.append(Int(row.u16(p)))
                }
            }
        }

        return try definition.columns.map { column -> Value in
            let present = column.number < rowColumns
            let notNull = present && row[maskStart + column.number / 8] & (1 << (column.number % 8)) != 0
            if column.type == .boolean { return .boolean(notNull) }
            guard notNull else { return .null }
            let bytes: [UInt8]
            if column.isFixedLength {
                let size = column.type.fixedSize ?? column.length
                let start = layout.rowColumnCountSize + column.fixedOffset
                guard start + size <= maskStart else { return .null }
                bytes = Array(row[start..<start + size])
            } else {
                guard column.variableIndex < rowVarColumns else { return .null }
                let start = varOffsets[column.variableIndex]
                let stop = varOffsets[column.variableIndex + 1]
                guard start <= stop, stop <= row.count else {
                    throw EngineError.corruptRow("variable column \(column.name) bounds")
                }
                bytes = Array(row[start..<stop])
            }
            return try decodeValue(bytes, column: column)
        }
    }

    /// Jet 3 stores one-byte variable column offsets plus a "jump table" that
    /// adds 256 for each boundary crossed in rows longer than 256 bytes.
    private func jet3VariableOffsets(_ row: [UInt8], maskSize: Int, varColumns: Int) -> [Int] {
        let end = row.count - 1
        var jumps = (row.count - 1) / 256
        let tablePointer = end - maskSize - jumps - 1
        if (tablePointer - varColumns) / 256 < jumps { jumps -= 1 }
        var used = 0
        var offsets: [Int] = []
        for i in 0...varColumns {
            while used < jumps, i == Int(row[end - maskSize - used - 1]) { used += 1 }
            offsets.append(Int(row[tablePointer - i]) + used * 256)
        }
        return offsets
    }

    func decodeValue(_ b: [UInt8], column: Column) throws -> Value {
        func need(_ n: Int) throws {
            if b.count < n { throw EngineError.corruptRow("\(column.name) needs \(n) bytes, has \(b.count)") }
        }
        switch column.type {
        case .boolean: return .boolean(true)
        case .byte: try need(1); return .byte(b[0])
        case .integer: try need(2); return .integer(b.i16(0))
        case .long: try need(4); return .long(b.i32(0))
        case .complex: try need(4); return .complex(b.i32(0))
        case .bigInt: try need(8); return .bigInt(b.i64(0))
        case .single: try need(4); return .single(b.f32(0))
        case .double: try need(8); return .double(b.f64(0))
        case .dateTime: try need(8); return .dateTime(AccessDate(rawValue: b.f64(0)))
        case .currency:
            try need(8)
            return .currency(Decimal(b.i64(0)) / 10_000)
        case .numeric:
            try need(17)
            return .decimal(Self.numeric(b, scale: column.scale))
        case .guid:
            try need(16)
            return .guid(Self.guid(b))
        case .text:
            return .text(database.codec.decode(b))
        case .binary, .unknown0D, .unknown11:
            return .binary(b)
        case .memo:
            return .text(database.codec.decode(try longValue(b)))
        case .ole:
            return .binary(try longValue(b))
        case .extendedDateTime:
            return .extendedDateTime(String(decoding: b, as: UTF8.self).trimmingCharacters(in: .whitespaces))
        }
    }

    /// Long values (memo and OLE) start with a 12-byte header: a length whose
    /// top bits say where the data is, and a pointer to the first LVAL row.
    func longValue(_ b: [UInt8]) throws -> [UInt8] {
        guard b.count >= 12 else { throw EngineError.corruptRow("long value header") }
        let header = b.u32(0)
        let length = Int(header & 0x3FFF_FFFF)
        let source = database.source
        switch header & 0xC000_0000 {
        case 0x8000_0000:
            return Array(b[12..<min(b.count, 12 + length)])
        case 0x4000_0000:
            let (row, _, _) = try source.row(at: RowPointer(raw: b.u32(4)))
            return Array(row.prefix(length))
        default:
            var result: [UInt8] = []
            result.reserveCapacity(length)
            var pointer = RowPointer(raw: b.u32(4))
            var seen: Set<RowPointer> = []
            while !pointer.isNull, result.count < length, !seen.contains(pointer) {
                seen.insert(pointer)
                let (row, _, _) = try source.row(at: pointer)
                guard row.count >= 4 else { break }
                result.append(contentsOf: row[4...])
                pointer = RowPointer(raw: row.u32(0))
            }
            return Array(result.prefix(length))
        }
    }

    /// Decimal: a sign byte and a 128-bit magnitude stored as four
    /// little-endian 32-bit words, most significant word first.
    static func numeric(_ b: [UInt8], scale: Int) -> Decimal {
        var words: [UInt32] = [b.u32(1), b.u32(5), b.u32(9), b.u32(13)]
        // Base-10 conversion by repeated division of the 128-bit magnitude.
        var digits: [UInt8] = []
        while words.contains(where: { $0 != 0 }) {
            var remainder: UInt64 = 0
            for i in 0..<4 {
                let current = remainder << 32 | UInt64(words[i])
                words[i] = UInt32(current / 10)
                remainder = current % 10
            }
            digits.append(UInt8(remainder))
        }
        if digits.isEmpty { return 0 }
        while digits.count <= scale { digits.append(0) }
        var text = String(digits.reversed().map { Character(String($0)) })
        if scale > 0 { text.insert(".", at: text.index(text.endIndex, offsetBy: -scale)) }
        if b[0] & 0x80 != 0 { text = "-" + text }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    static func guid(_ b: [UInt8]) -> String {
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }
        return "{" + hex([b[3], b[2], b[1], b[0]]) + "-" + hex([b[5], b[4]]) + "-" + hex([b[7], b[6]])
            + "-" + hex(Array(b[8..<10])) + "-" + hex(Array(b[10..<16])) + "}"
    }
}
