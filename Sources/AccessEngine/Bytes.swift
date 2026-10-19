import Foundation

/// Little-endian readers over a byte buffer. Every multi-byte integer in the
/// Jet/ACE file format is little-endian.
extension Array where Element == UInt8 {
    @inline(__always) func u8(_ offset: Int) -> UInt8 { self[offset] }

    @inline(__always) func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    @inline(__always) func i16(_ offset: Int) -> Int16 { Int16(bitPattern: u16(offset)) }

    @inline(__always) func u24(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16
    }

    @inline(__always) func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    @inline(__always) func i32(_ offset: Int) -> Int32 { Int32(bitPattern: u32(offset)) }

    @inline(__always) func u64(_ offset: Int) -> UInt64 {
        UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32
    }

    @inline(__always) func i64(_ offset: Int) -> Int64 { Int64(bitPattern: u64(offset)) }

    @inline(__always) func f32(_ offset: Int) -> Float { Float(bitPattern: u32(offset)) }

    @inline(__always) func f64(_ offset: Int) -> Double { Double(bitPattern: u64(offset)) }

    /// A copy of `count` bytes starting at `offset`, clamped to the buffer.
    func bytes(_ offset: Int, _ count: Int) -> [UInt8] {
        guard offset >= 0, count > 0, offset < self.count else { return [] }
        return Array(self[offset..<Swift.min(offset + count, self.count)])
    }
}

/// A (page, row) pointer as stored throughout the format: the low byte is the
/// row number and the upper three bytes are the page number.
public struct RowPointer: Hashable, Sendable, CustomStringConvertible {
    public var page: UInt32
    public var row: UInt8

    public init(page: UInt32, row: UInt8) {
        self.page = page
        self.row = row
    }

    init(raw: UInt32) {
        page = raw >> 8
        row = UInt8(raw & 0xFF)
    }

    var isNull: Bool { page == 0 && row == 0 }

    public var description: String { "\(page):\(row)" }
}
