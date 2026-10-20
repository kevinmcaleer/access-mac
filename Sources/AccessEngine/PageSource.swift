import Foundation

/// Decoded fields of the database header (page 0).
public struct DatabaseHeader: Sendable {
    public let format: FileFormat
    public let codePage: UInt16
    /// Non-zero when a Jet 3/4 database has been "encoded": every page after
    /// the header is RC4-encrypted with this key mixed with the page number.
    public let databaseKey: UInt32
    /// The decrypted header region, kept for features that need more fields.
    let decrypted: [UInt8]
}

/// Random access to the pages of a database file, with header
/// de-obfuscation, page decryption and a small page cache.
final class PageSource {
    let data: Data
    let header: DatabaseHeader
    let layout: Layout
    private(set) var pageCount: UInt32
    private var cache: [UInt32: [UInt8]] = [:]
    /// Pages changed or added since the file was read, decrypted.
    private var dirty: [UInt32: [UInt8]] = [:]
    private let lock = NSLock()
    /// The database's map of free pages (page 1, row 0), loaded on first
    /// allocation.
    private var globalMap: UsageMapEditor?

    private static let headerKey: [UInt8] = [0xC7, 0xDA, 0x39, 0x6B]

    init(data: Data) throws {
        self.data = data
        guard data.count >= 2048 else { throw EngineError.notAnAccessDatabase }
        var page0 = [UInt8](data.prefix(4096))
        guard page0[0] == 0x00, page0[1] == 0x01, page0[2] == 0x00, page0[3] == 0x00 else {
            throw EngineError.notAnAccessDatabase
        }
        let signature = String(decoding: page0[4..<19], as: UTF8.self)
        guard signature == "Standard Jet DB" || signature == "Standard ACE DB" else {
            throw EngineError.notAnAccessDatabase
        }
        let format = try FileFormat(versionByte: page0[0x14])
        let layout = format.layout
        self.layout = layout

        var rc4 = RC4(key: Self.headerKey)
        let start = 0x18
        rc4.apply(&page0, range: start..<min(start + layout.headerEncryptedLength, page0.count))

        let codePage = page0.u16(0x3C)
        let dbKey = page0.u32(0x3E)
        header = DatabaseHeader(format: format, codePage: codePage,
                                databaseKey: format.isACE ? 0 : dbKey, decrypted: page0)
        pageCount = UInt32(data.count / layout.pageSize)
    }

    /// The bytes of page `number`, decrypted.
    func page(_ number: UInt32) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if let changed = dirty[number] { return changed }
        if let cached = cache[number] { return cached }
        guard number < pageCount else { throw EngineError.pageOutOfRange(number) }
        let size = layout.pageSize
        let offset = Int(number) * size
        var bytes = [UInt8](data[data.startIndex + offset..<data.startIndex + offset + size])
        if number > 0, header.databaseKey != 0 {
            let key = header.databaseKey ^ number
            var rc4 = RC4(key: [UInt8(key & 0xFF), UInt8(key >> 8 & 0xFF),
                                UInt8(key >> 16 & 0xFF), UInt8(key >> 24 & 0xFF)])
            rc4.apply(&bytes, range: 0..<size)
        }
        if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
        cache[number] = bytes
        return bytes
    }

    /// The raw bytes of row `pointer.row` on data page `pointer.page`, along
    /// with the row's flags.
    func row(at pointer: RowPointer) throws -> (bytes: [UInt8], deleted: Bool, overflow: Bool) {
        let page = try page(pointer.page)
        guard page[0] == PageType.data.rawValue else {
            throw EngineError.corruptPage(pointer.page, "expected a data page for row \(pointer)")
        }
        let count = Int(page.u16(layout.dataRowCountOffset))
        let row = Int(pointer.row)
        guard row < count else {
            throw EngineError.corruptPage(pointer.page, "row \(row) of \(count)")
        }
        let (start, end, deleted, overflow) = rowBounds(page, row: row)
        guard start <= end, end <= page.count else {
            throw EngineError.corruptPage(pointer.page, "row \(row) bounds \(start)..<\(end)")
        }
        return (Array(page[start..<end]), deleted, overflow)
    }

    /// Byte range and flags of row `row` on a data page. A row ends where the
    /// previous row (which is stored after it) begins.
    func rowBounds(_ page: [UInt8], row: Int) -> (start: Int, end: Int, deleted: Bool, overflow: Bool) {
        let tableStart = layout.dataRowCountOffset + 2
        let raw = page.u16(tableStart + row * 2)
        let start = Int(raw & 0x1FFF)
        var end = layout.pageSize
        if row > 0 { end = Int(page.u16(tableStart + (row - 1) * 2) & 0x1FFF) }
        return (start, end, raw & 0x8000 != 0, raw & 0x4000 != 0)
    }

    func rowCount(onDataPage page: [UInt8]) -> Int { Int(page.u16(layout.dataRowCountOffset)) }

    // MARK: Writing

    var hasChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !dirty.isEmpty
    }

    func writePage(_ number: UInt32, _ bytes: [UInt8]) {
        precondition(bytes.count == layout.pageSize, "page \(number) has the wrong size")
        lock.lock()
        dirty[number] = bytes
        cache[number] = nil
        lock.unlock()
    }

    /// Adds a zeroed page at the end of the file and marks it in use in the
    /// global usage map.
    func allocatePage() throws -> UInt32 {
        lock.lock()
        let number = pageCount
        pageCount += 1
        dirty[number] = [UInt8](repeating: 0, count: layout.pageSize)
        lock.unlock()
        try globalUsageMap().remove(number)
        return number
    }

    /// Marks a page as free. Only its header is cleared, as Jet does.
    func deallocatePage(_ number: UInt32) throws {
        var bytes = try page(number)
        bytes.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        writePage(number, bytes)
        try globalUsageMap().add(number)
    }

    private func globalUsageMap() throws -> UsageMapEditor {
        if let globalMap { return globalMap }
        let map = try UsageMapEditor(source: self, pointer: RowPointer(page: 1, row: 0), isGlobal: true)
        globalMap = map
        return map
    }

    /// The whole file with every change applied, re-encoded if the database
    /// is encoded.
    func serialized() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let size = layout.pageSize
        var out = Data(count: Int(pageCount) * size)
        out.replaceSubrange(0..<min(data.count, out.count), with: data.prefix(out.count))
        for (number, var bytes) in dirty {
            if number > 0, header.databaseKey != 0 {
                let key = header.databaseKey ^ number
                var rc4 = RC4(key: [UInt8(key & 0xFF), UInt8(key >> 8 & 0xFF),
                                    UInt8(key >> 16 & 0xFF), UInt8(key >> 24 & 0xFF)])
                rc4.apply(&bytes, range: 0..<size)
            }
            let offset = Int(number) * size
            out.replaceSubrange(offset..<offset + size, with: bytes)
        }
        return out
    }
}
