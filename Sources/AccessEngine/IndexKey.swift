import Foundation

// Index key encoding: each key column contributes a flag byte (start or
// null, ascending or descending) and an order-preserving encoding of its
// value, so keys sort correctly as plain byte strings. Ported from Jackcess's
// IndexData column descriptors (Apache License 2.0).

enum IndexKeyError: Error, Equatable {
    case unsupportedType(ColumnType)
    case valueTypeMismatch(String)
}

struct IndexKeyEncoder {
    let format: FileFormat

    private static let ascStart: UInt8 = 0x7F
    private static let ascNull: UInt8 = 0x00
    private static let descStart: UInt8 = 0x80
    private static let descNull: UInt8 = 0xFF

    /// The key for `row` (one value per table column, in column order).
    func key(for index: Index, columns: [Column], row: [Value]) throws -> [UInt8] {
        var out: [UInt8] = []
        for keyColumn in index.columns {
            guard let position = columns.firstIndex(where: { $0.number == keyColumn.number }) else { continue }
            try append(row[position], column: columns[position], ascending: keyColumn.ascending, to: &out)
        }
        return out
    }

    func append(_ value: Value, column: Column, ascending: Bool, to out: inout [UInt8]) throws {
        if column.type == .boolean {
            out.append(ascending ? Self.ascStart : Self.descStart)
            let isTrue = value == .boolean(true)
            out.append(isTrue == ascending ? 0x00 : 0xFF)
            return
        }
        if value.isNull {
            out.append(ascending ? Self.ascNull : Self.descNull)
            return
        }
        out.append(ascending ? Self.ascStart : Self.descStart)

        switch (column.type, value) {
        case (.text, .text(let s)), (.memo, .text(let s)):
            try TextIndexCodes.forSortOrder(column.sortOrder).encode(s, ascending: ascending, into: &out)

        case (.byte, .byte(let v)):
            out.append(ascending ? v : ~v)

        case (.integer, .integer(let v)):
            out.append(contentsOf: Self.integer(UInt64(UInt16(bitPattern: v)), bytes: 2, ascending: ascending))
        case (.long, .long(let v)), (.complex, .complex(let v)):
            out.append(contentsOf: Self.integer(UInt64(UInt32(bitPattern: v)), bytes: 4, ascending: ascending))
        case (.bigInt, .bigInt(let v)):
            out.append(contentsOf: Self.integer(UInt64(bitPattern: v), bytes: 8, ascending: ascending))
        case (.currency, .currency(let v)):
            let scaled = NSDecimalNumber(decimal: v * 10_000).int64Value
            out.append(contentsOf: Self.integer(UInt64(bitPattern: scaled), bytes: 8, ascending: ascending))

        case (.single, .single(let v)):
            out.append(contentsOf: Self.floating(UInt64(v.bitPattern), bytes: 4, ascending: ascending))
        case (.double, .double(let v)):
            out.append(contentsOf: Self.floating(v.bitPattern, bytes: 8, ascending: ascending))
        case (.dateTime, .dateTime(let d)):
            out.append(contentsOf: Self.floating(d.rawValue.bitPattern, bytes: 8, ascending: ascending))

        case (.numeric, .decimal(let d)):
            var bytes = Self.numericBigEndian(d, scale: column.scale)
            let negative = bytes[0] & 0x80 != 0
            if format == .jet3 || format == .jet4 {
                // Access 2000-2003 sorted negative decimals wrongly (KB 837148).
                if negative == ascending { Self.flip(&bytes) }
                bytes[0] = negative ? 0x00 : 0xFF
            } else {
                bytes[0] = 0xFF
                if negative == ascending { Self.flip(&bytes) }
            }
            out.append(contentsOf: bytes)

        case (.guid, .guid(let g)):
            out.append(contentsOf: Self.binaryEntry(Self.guidBytes(g), ascending: ascending))
        case (.binary, .binary(let b)):
            out.append(contentsOf: Self.binaryEntry(b, ascending: ascending))

        case (.extendedDateTime, .extendedDateTime(let s)):
            var bytes = Array(s.utf8.prefix(42))
            bytes.append(contentsOf: repeatElement(0x20, count: max(0, 42 - bytes.count)))
            var trailer: [UInt8] = [0, 0, 0, 0, 0, 0, 0x02]
            if !ascending {
                Self.flip(&bytes)
                Self.flip(&trailer)
            }
            for block in 0..<5 {
                out.append(contentsOf: bytes[block * 8..<block * 8 + 8])
                out.append(0x09)
            }
            out.append(contentsOf: bytes[40..<42])
            out.append(contentsOf: trailer)

        case (.ole, _), (.unknown0D, _), (.unknown11, _):
            throw IndexKeyError.unsupportedType(column.type)
        default:
            throw IndexKeyError.valueTypeMismatch("\(column.name): \(value)")
        }
    }

    /// Big-endian two's complement with the sign bit flipped.
    private static func integer(_ v: UInt64, bytes: Int, ascending: Bool) -> [UInt8] {
        var out = (0..<bytes).map { UInt8(truncatingIfNeeded: v >> UInt64((bytes - 1 - $0) * 8)) }
        out[0] ^= 0x80
        if !ascending { flip(&out) }
        return out
    }

    /// Big-endian IEEE: positives get the sign bit flipped, negatives are
    /// inverted entirely, so the byte order matches numeric order.
    private static func floating(_ bits: UInt64, bytes: Int, ascending: Bool) -> [UInt8] {
        var out = (0..<bytes).map { UInt8(truncatingIfNeeded: bits >> UInt64((bytes - 1 - $0) * 8)) }
        let negative = out[0] & 0x80 != 0
        if !negative { out[0] ^= 0x80 }
        if negative == ascending { flip(&out) }
        return out
    }

    /// Binary data in 8-byte segments, each followed by a length byte; 9
    /// means more segments follow.
    static func binaryEntry(_ data: [UInt8], ascending: Bool) -> [UInt8] {
        var out: [UInt8] = []
        var position = 0
        var remaining = data.count
        while remaining > 8 {
            var segment = Array(data[position..<position + 8])
            if !ascending { flip(&segment) }
            out.append(contentsOf: segment)
            out.append(0x09)
            position += 8
            remaining -= 8
        }
        if remaining > 0 {
            var segment = Array(data[position..<position + remaining])
            segment.append(contentsOf: repeatElement(0, count: 8 - remaining))
            segment.append(UInt8(remaining))
            if !ascending { flip(&segment) }
            out.append(contentsOf: segment)
        }
        return out
    }

    /// The GUID's bytes in the order its text is written.
    static func guidBytes(_ text: String) -> [UInt8] {
        let hex = text.filter(\.isHexDigit)
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    /// Sign byte then a 16-byte big-endian magnitude, scaled to `scale`.
    static func numericBigEndian(_ value: Decimal, scale: Int) -> [UInt8] {
        var scaled = value
        var rounded = Decimal()
        for _ in 0..<scale { scaled *= 10 }
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        var digits = "\(rounded)"
        var negative = false
        if digits.hasPrefix("-") {
            negative = true
            digits.removeFirst()
        }
        // Base conversion of the decimal digit string into 128 bits.
        var words = [UInt32](repeating: 0, count: 4)
        for character in digits {
            guard let digit = character.wholeNumberValue else { continue }
            var carry = UInt64(digit)
            for i in (0..<4).reversed() {
                let product = UInt64(words[i]) * 10 + carry
                words[i] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
        }
        var out: [UInt8] = [negative ? 0x80 : 0x00]
        for word in words {
            out.append(contentsOf: [UInt8(word >> 24), UInt8(word >> 16 & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word & 0xFF)])
        }
        return out
    }

    static func flip(_ bytes: inout [UInt8]) {
        for i in bytes.indices { bytes[i] = ~bytes[i] }
    }
}
