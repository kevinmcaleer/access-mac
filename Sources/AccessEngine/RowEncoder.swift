import Foundation

// Encoding rows for writing: the inverse of RowDecoder, laid out the way
// Access and Jackcess write them (Jackcess TableImpl.createRow).

public enum WriteError: Error, Equatable, CustomStringConvertible {
    case readOnlyFormat(FileFormat)
    case valueTooLong(column: String, limit: Int)
    case invalidValue(column: String, expected: String)
    case rowTooLarge(Int)
    case requiredValueMissing(String)
    case duplicateKey(index: String)
    case rowNotFound
    case unsupported(String)

    public var description: String {
        switch self {
        case .readOnlyFormat(let f): return "\(f.displayName) databases can't be edited yet."
        case .valueTooLong(let c, let limit): return "The value for \(c) is longer than its field size (\(limit))."
        case .invalidValue(let c, let expected): return "\(c) needs \(expected)."
        case .rowTooLarge(let size): return "The record is too large (\(size) bytes)."
        case .requiredValueMissing(let c): return "\(c) can't be empty."
        case .duplicateKey(let index): return "The change would create a duplicate value in the index \(index)."
        case .rowNotFound: return "The record no longer exists."
        case .unsupported(let what): return "\(what) is not supported yet."
        }
    }
}

struct RowEncoder {
    let format: FileFormat
    let definition: TableDefinition

    static let maxRowSize = 4060
    static let maxInlineLongValue = 64
    static let longValueHeaderSize = 12

    /// Bytes for a fixed-length value, little-endian as stored.
    func fixedBytes(_ value: Value, column: Column) throws -> [UInt8] {
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        func bad(_ what: String) -> WriteError { .invalidValue(column: column.name, expected: what) }
        switch (column.type, value) {
        case (.byte, .byte(let v)): return [v]
        case (.integer, .integer(let v)): return le(v)
        case (.long, .long(let v)), (.complex, .complex(let v)): return le(v)
        case (.bigInt, .bigInt(let v)): return le(v)
        case (.single, .single(let v)): return le(v.bitPattern)
        case (.double, .double(let v)): return le(v.bitPattern)
        case (.dateTime, .dateTime(let d)): return le(d.rawValue.bitPattern)
        case (.currency, .currency(let d)):
            let scaled = d * 10_000
            var rounded = Decimal()
            var source = scaled
            NSDecimalRound(&rounded, &source, 0, .plain)
            guard rounded.magnitude <= Decimal(Int64.max) else { throw bad("a currency amount in range") }
            return le(NSDecimalNumber(decimal: rounded).int64Value)
        case (.numeric, .decimal(let d)):
            let be = IndexKeyEncoder.numericBigEndian(d, scale: column.scale)
            // Stored as a sign byte and four little-endian words, most
            // significant word first.
            var out: [UInt8] = [be[0]]
            for word in 0..<4 {
                out.append(contentsOf: be[(1 + word * 4)..<(5 + word * 4)].reversed())
            }
            return out
        case (.guid, .guid(let g)):
            let b = IndexKeyEncoder.guidBytes(g)
            guard b.count == 16 else { throw bad("a GUID like {00000000-0000-0000-0000-000000000000}") }
            return [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + Array(b[8..<16])
        case (.extendedDateTime, .extendedDateTime(let s)):
            var bytes = Array(s.utf8.prefix(42))
            bytes.append(contentsOf: repeatElement(0x20, count: 42 - bytes.count))
            return bytes
        default:
            throw bad(column.type.accessName.lowercased() + " value")
        }
    }

    /// Bytes for a variable-length value that is stored in the row.
    func inlineVariableBytes(_ value: Value, column: Column) throws -> [UInt8] {
        switch (column.type, value) {
        case (.text, .text(let s)):
            let units = Array(s.utf16)
            guard units.count * 2 <= column.length else {
                throw WriteError.valueTooLong(column: column.name, limit: column.size)
            }
            return Self.utf16(units)
        case (.binary, .binary(let b)), (.unknown0D, .binary(let b)), (.unknown11, .binary(let b)):
            guard b.count <= max(column.length, 255) else {
                throw WriteError.valueTooLong(column: column.name, limit: column.length)
            }
            return b
        case (.text, _), (.binary, _), (.unknown0D, _), (.unknown11, _):
            throw WriteError.invalidValue(column: column.name, expected: column.type.accessName.lowercased() + " value")
        default:
            // Fixed-size types can be stored as variable columns (Jackcess
            // writes Decimal this way).
            return try fixedBytes(value, column: column)
        }
    }

    /// The raw bytes a long value column stores (text as UTF-16LE).
    func longValueData(_ value: Value, column: Column) throws -> [UInt8] {
        switch (column.type, value) {
        case (.memo, .text(let s)): return Self.utf16(Array(s.utf16))
        case (.ole, .binary(let b)): return b
        default:
            throw WriteError.invalidValue(column: column.name, expected: column.type.accessName.lowercased() + " value")
        }
    }

    static func utf16(_ units: [UInt16]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(units.count * 2)
        for u in units { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
        return out
    }

    /// Lays out a row. `variable` holds the already-encoded bytes of each
    /// non-null variable column (long values as their 12-byte header).
    /// `minimumSize` pads the row, so an update can reuse the old slot.
    func encode(values: [Value], variable: [Int: [UInt8]], minimumSize: Int = 0) throws -> [UInt8] {
        let columns = definition.columns
        let maxColumns = definition.maxColumnCount
        var nullMask = [UInt8](repeating: 0, count: (maxColumns + 7) / 8)
        func markNotNull(_ c: Column) { nullMask[c.number / 8] |= 1 << (c.number % 8) }

        var row: [UInt8] = [UInt8(maxColumns & 0xFF), UInt8(maxColumns >> 8)]
        var fixedEnd = row.count
        for (i, column) in columns.enumerated() where column.isFixedLength {
            if column.type == .boolean {
                if values[i] == .boolean(true) { markNotNull(column) }
            } else if !values[i].isNull {
                let bytes = try fixedBytes(values[i], column: column)
                let start = 2 + column.fixedOffset
                if row.count < start + bytes.count {
                    row.append(contentsOf: repeatElement(0, count: start + bytes.count - row.count))
                }
                row.replaceSubrange(start..<start + bytes.count, with: bytes)
                markNotNull(column)
            }
            // Access expects room for every fixed column, null or not.
            fixedEnd = max(fixedEnd, 2 + column.fixedOffset + column.length)
        }
        if row.count < fixedEnd { row.append(contentsOf: repeatElement(0, count: fixedEnd - row.count)) }

        let varCount = definition.numVarColumns
        if varCount > 0 {
            let trailer = nullMask.count + 4 + varCount * 2
            var offsets = [UInt16](repeating: 0, count: varCount)
            var next = 0
            let variableColumns = columns.enumerated().filter { !$0.element.isFixedLength }
                .sorted { $0.element.variableIndex < $1.element.variableIndex }
            for (i, column) in variableColumns {
                let offset = UInt16(row.count)
                if let bytes = variable[i] {
                    row.append(contentsOf: bytes)
                    markNotNull(column)
                }
                while next <= column.variableIndex, next < varCount {
                    offsets[next] = offset
                    next += 1
                }
            }
            while next < varCount {
                offsets[next] = UInt16(row.count)
                next += 1
            }
            let eod = UInt16(row.count)
            if row.count + trailer < minimumSize {
                row.append(contentsOf: repeatElement(0, count: minimumSize - row.count - trailer))
            }
            row.append(UInt8(eod & 0xFF)); row.append(UInt8(eod >> 8))
            for offset in offsets.reversed() { row.append(UInt8(offset & 0xFF)); row.append(UInt8(offset >> 8)) }
            row.append(UInt8(varCount & 0xFF)); row.append(UInt8(varCount >> 8))
        } else if row.count + nullMask.count < minimumSize {
            row.append(contentsOf: repeatElement(0, count: minimumSize - row.count - nullMask.count))
        }
        row.append(contentsOf: nullMask)
        guard row.count <= Self.maxRowSize else { throw WriteError.rowTooLarge(row.count) }
        return row
    }
}
