import Foundation

// Text index key encoding for the "General" and "General - Legacy" sort
// orders. Ported from Jackcess's GeneralLegacyIndexCodes (Apache License 2.0,
// see Resources/IndexCodes/NOTICE); the per-character code tables are
// Jackcess's.

/// How one UTF-16 code unit contributes to a text index key.
enum CharCode {
    case simple([UInt8])
    case international(inline: [UInt8], extra: [UInt8])
    case unprintable([UInt8])
    case unprintableModifier(UInt8)
    case internationalExt(inline: [UInt8], extra: [UInt8]?, crazy: UInt8)
    case significant([UInt8])
    case ignored
    case surrogate

    var inline: [UInt8]? {
        switch self {
        case .simple(let b), .significant(let b): return b
        case .international(let b, _), .internationalExt(let b, _, _): return b
        default: return nil
        }
    }
}

enum TextIndexError: Error, Equatable {
    case unsupportedSortOrder(UInt16, UInt8)
    case surrogateCharacter
}

/// The code tables for one sort order, loaded on first use.
final class TextIndexCodes {
    private let codes: [CharCode]

    static let general = TextIndexCodes(base: "index_codes_gen", ext: "index_codes_ext_gen")
    static let generalLegacy = TextIndexCodes(base: "index_codes_genleg", ext: "index_codes_ext_genleg")

    static func forSortOrder(_ order: SortOrder) throws -> TextIndexCodes {
        switch order {
        case .general: return general
        case .generalLegacy: return generalLegacy
        default: throw TextIndexError.unsupportedSortOrder(order.value, order.version)
        }
    }

    private init(base: String, ext: String) {
        var codes: [CharCode] = []
        codes.reserveCapacity(65536)
        Self.load(base, into: &codes, from: 0x0000, to: 0x00FF)
        Self.load(ext, into: &codes, from: 0x0100, to: 0xFFFF)
        self.codes = codes
    }

    private static func load(_ name: String, into codes: inout [CharCode], from first: Int, to last: Int) {
        let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "IndexCodes")
            ?? Bundle.module.url(forResource: name, withExtension: "txt")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .ascii) } ?? ""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        for unit in first...last {
            if (0xD800...0xDFFF).contains(unit) {
                codes.append(.surrogate)
                continue
            }
            guard let line = lines.next(), let prefix = line.first else {
                codes.append(.ignored)
                continue
            }
            let fields = line.dropFirst().split(separator: ",", omittingEmptySubsequences: false).map { hex(String($0)) }
            switch prefix {
            case "S": codes.append(.simple(fields[0]))
            case "I": codes.append(.international(inline: fields[0], extra: fields[1]))
            case "U": codes.append(.unprintable(fields[0]))
            case "P": codes.append(.unprintableModifier(fields[0].first ?? 0))
            case "Z":
                let crazy: UInt8 = line.hasSuffix(",1") ? 0x02 : 0x03
                codes.append(.internationalExt(inline: fields[0], extra: fields[1].isEmpty ? nil : fields[1], crazy: crazy))
            case "G": codes.append(.significant(fields[0]))
            default: codes.append(.ignored)
            }
        }
    }

    private static func hex(_ s: String) -> [UInt8] {
        let padded = s.count % 2 == 0 ? s : "0" + s
        var bytes: [UInt8] = []
        var index = padded.startIndex
        while index < padded.endIndex {
            let next = padded.index(index, offsetBy: 2)
            bytes.append(UInt8(padded[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    // Markers used in the key.
    private static let endText: UInt8 = 0x01
    private static let endExtraText: UInt8 = 0x00
    private static let internationalPlaceholder: UInt8 = 0x02
    private static let crazyCodeStart: UInt8 = 0x80
    private static let crazyCodesSuffix: [UInt8] = [0xFF, 0x02, 0x80, 0xFF, 0x80]
    private static let crazyCodesUnprintSuffix: UInt8 = 0xFF
    /// Text is indexed only up to the length of a Short Text column.
    static let maxIndexedCharacters = 255

    /// Appends the encoding of non-null text `value` to `out`.
    func encode(_ value: String, ascending: Bool, into out: inout [UInt8]) throws {
        var units = Array(value.utf16.prefix(Self.maxIndexedCharacters))
        while units.last == 0x20 { units.removeLast() }   // trailing spaces are ignored

        let start = out.count
        var extra: [UInt8]? = nil
        var extraChars = 0
        var unprintablePrefix = 0
        var unprintable: [UInt8]? = nil
        var crazy: [UInt8]? = nil
        var charOffset = 0

        for unit in units {
            let code = codes[Int(unit)]
            if case .surrogate = code { throw TextIndexError.surrogateCharacter }
            let offset = charOffset
            if let inline = code.inline {
                out.append(contentsOf: inline)
                charOffset += 1
            }
            if case .simple = code { continue }

            var extraBytes: [UInt8]? = nil
            var modifier: UInt8 = 0
            switch code {
            case .international(_, let e): extraBytes = e
            case .internationalExt(_, let e, _): extraBytes = e
            case .unprintableModifier(let m): modifier = m
            default: break
            }
            if extraBytes != nil || modifier != 0 {
                if extra == nil { extra = [] }
                if extraChars < offset {
                    extra!.append(contentsOf: repeatElement(Self.internationalPlaceholder, count: offset - extraChars))
                    extraChars = offset
                }
                if let extraBytes {
                    extra!.append(contentsOf: extraBytes)
                    extraChars += 1
                } else if !extra!.isEmpty {
                    extra![extra!.count - 1] &+= modifier
                } else {
                    extra!.append(modifier)
                    unprintablePrefix = 1
                }
            }

            if case .unprintable(let bytes) = code {
                if unprintable == nil { unprintable = [] }
                var position = offset
                if let extra {
                    position = extra.count + (offset - extraChars) - unprintablePrefix
                }
                let marker = (7 + 4 * position) | 0x8000
                unprintable!.append(UInt8(marker >> 8 & 0xFF))
                unprintable!.append(UInt8(marker & 0xFF))
                unprintable!.append(0x06)
                unprintable!.append(contentsOf: bytes)
            }

            if case .internationalExt(_, _, let flag) = code {
                if crazy == nil { crazy = [] }
                crazy!.append(flag)
            }
        }

        out.append(Self.endText)
        if var e = extra {
            while let last = e.last, last <= Self.internationalPlaceholder { e.removeLast() }
            extra = e.isEmpty ? nil : e
        }
        if extra != nil || unprintable != nil || crazy != nil {
            if let extra { out.append(contentsOf: extra) }
            if crazy != nil || unprintable != nil {
                out.append(Self.endText)
                out.append(Self.endText)
                if var flags = crazy {
                    while flags.last == 0x03 { flags.removeLast() }
                    var current = Self.crazyCodeStart
                    var count = 0
                    for flag in flags {
                        current |= flag << UInt8((2 - count) * 2)
                        count += 1
                        if count == 3 {
                            out.append(current)
                            current = Self.crazyCodeStart
                            count = 0
                        }
                    }
                    if count > 0 { out.append(current) }
                    out.append(contentsOf: Self.crazyCodesSuffix)
                    if unprintable != nil { out.append(Self.crazyCodesUnprintSuffix) }
                }
                if let unprintable {
                    out.append(Self.endText)
                    out.append(contentsOf: unprintable)
                }
            }
        }

        if !ascending {
            out.append(Self.endExtraText)
            for i in start..<out.count { out[i] = ~out[i] }
        }
        out.append(Self.endExtraText)
    }
}
