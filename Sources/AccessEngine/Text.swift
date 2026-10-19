import Foundation

/// Text decoding for the two encodings Jet uses: Jet 3 stores text in the
/// database code page, Jet 4 and ACE store UTF-16LE, optionally "compressed".
struct TextCodec {
    let format: FileFormat
    let codePage: UInt16

    func decode(_ bytes: [UInt8]) -> String {
        if format.isJet3 { return Self.decodeCodePage(bytes, codePage: codePage) }
        return Self.decodeJet4(bytes)
    }

    /// Jet 4 text. A leading `FF FE` marks Unicode compression: runs of
    /// characters whose high byte is zero are stored as single bytes, and a
    /// zero byte toggles between compressed and uncompressed runs.
    static func decodeJet4(_ bytes: [UInt8]) -> String {
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count)
            var compressed = true
            var i = 2
            while i < bytes.count {
                if bytes[i] == 0 {
                    compressed.toggle()
                    i += 1
                } else if compressed {
                    units.append(UInt16(bytes[i]))
                    i += 1
                } else if i + 1 < bytes.count {
                    units.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
                    i += 2
                } else {
                    break
                }
            }
            return String(decoding: units, as: UTF16.self)
        }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            units.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func decodeCodePage(_ bytes: [UInt8], codePage: UInt16) -> String {
        let encoding: String.Encoding
        switch codePage {
        case 1250: encoding = .windowsCP1250
        case 1251: encoding = .windowsCP1251
        case 1253: encoding = .windowsCP1253
        case 1254: encoding = .windowsCP1254
        case 932: encoding = .shiftJIS
        default: encoding = .windowsCP1252
        }
        return String(bytes: bytes, encoding: encoding) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Names in a table definition: a length prefix (2 bytes in Jet 4, 1 in
    /// Jet 3) followed by the encoded text. Returns the name and its size.
    func readName(_ buffer: [UInt8], at offset: Int) -> (String, Int) {
        if format.isJet3 {
            let length = Int(buffer[offset])
            return (decode(buffer.bytes(offset + 1, length)), 1 + length)
        }
        let length = Int(buffer.u16(offset))
        return (decode(buffer.bytes(offset + 2, length)), 2 + length)
    }
}
