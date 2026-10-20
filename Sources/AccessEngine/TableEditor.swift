import Foundation

// Changing tables: inserting, updating and deleting rows, writing long
// values and keeping indexes in step. Follows Jackcess's TableImpl,
// LongValueColumnImpl and IndexData (Apache License 2.0), which lay data
// out the way Access does.

extension Table {
    /// Why the table can't be edited, or nil when it can.
    public var editingRestriction: String? {
        if database.format.isJet3 { return WriteError.readOnlyFormat(database.format).description }
        if columns.contains(where: \.isCalculated) { return "Tables with calculated fields can't be edited yet." }
        return nil
    }

    /// Adds a record. `values` has one entry per column, in column order;
    /// AutoNumber fields are filled in unless `keepingAutoNumbers` is set and
    /// a value is given (as when restoring a deleted record). Returns the new
    /// row's location and the values as stored.
    @discardableResult
    public func insertRow(_ values: [Value], keepingAutoNumbers: Bool = false) throws
        -> (location: RowPointer, values: [Value]) {
        try editor().insert(values, keepingAutoNumbers: keepingAutoNumbers)
    }

    /// Replaces the values of the record at `location`. AutoNumber fields
    /// keep their values. Returns the values as stored.
    @discardableResult
    public func updateRow(at location: RowPointer, with values: [Value]) throws -> [Value] {
        try editor().update(location, values: values)
    }

    /// Deletes the record at `location`.
    public func deleteRow(at location: RowPointer) throws {
        try editor().delete(location)
    }

    func editor() throws -> TableEditor {
        if let restriction = editingRestriction {
            if database.format.isJet3 { throw WriteError.readOnlyFormat(database.format) }
            throw WriteError.unsupported(restriction)
        }
        if let editorStorage { return editorStorage }
        let editor = try TableEditor(table: self)
        editorStorage = editor
        return editor
    }
}

/// Write state for one table: its page maps, counters and indexes.
final class TableEditor {
    unowned let table: Table
    let source: PageSource
    let encoder: RowEncoder
    private let owned: UsageMapEditor
    private let free: UsageMapEditor
    private(set) var rowCount: Int
    private var lastAutoNumber: Int32
    private var lastComplexAutoNumber: Int32
    /// The page the last insert used, tried first by the next one.
    private var insertPage: UInt32?
    private var longValuePages: [Int: LongValuePages] = [:]
    private var loadedIndexes: [EditableIndex]?

    private var definition: TableDefinition { table.definition }
    private var layout: Layout { source.layout }
    private var rowCountOffset: Int { layout.dataRowCountOffset }
    private var complexAutoNumberOffset: Int? { table.database.format.isACE ? 28 : nil }

    static let maxRowsPerPage = 255
    static let maxLongValueRow = 4076
    static let deletedFlag: UInt16 = 0x8000
    static let overflowFlag: UInt16 = 0x4000

    init(table: Table) throws {
        self.table = table
        source = table.database.source
        encoder = RowEncoder(format: table.database.format, definition: table.definition)
        owned = try UsageMapEditor(source: source, pointer: table.definition.usageMap)
        free = try UsageMapEditor(source: source, pointer: table.definition.freeMap)
        let tdef = try source.page(table.definition.page)
        rowCount = Int(tdef.u32(source.layout.tdefNumRowsOffset))
        lastAutoNumber = tdef.i32(20)
        lastComplexAutoNumber = table.database.format.isACE ? tdef.i32(28) : 0
    }

    // MARK: Rows

    func insert(_ input: [Value], keepingAutoNumbers: Bool) throws -> (location: RowPointer, values: [Value]) {
        var values = normalized(input)
        let columns = definition.columns
        if columns.contains(where: { $0.type == .complex }) {
            throw WriteError.unsupported("Adding records to tables with attachment or multi-value fields")
        }
        var nextAutoNumber = lastAutoNumber
        for (i, column) in columns.enumerated() where column.isAutoNumber {
            if keepingAutoNumbers, case .long(let kept) = values[i] {
                nextAutoNumber = max(nextAutoNumber, kept)
                continue
            }
            if keepingAutoNumbers, case .guid = values[i] { continue }
            switch column.type {
            case .long:
                nextAutoNumber += 1
                values[i] = .long(nextAutoNumber)
            case .guid:
                values[i] = .guid("{" + UUID().uuidString + "}")
            default:
                break
            }
        }
        // Check everything that can fail before any page changes.
        _ = try encodeRow(values, writeLongValues: false)
        let keys = try indexKeys(for: values)
        let indexes = try editableIndexes()
        for (index, key) in zip(indexes, keys) {
            try index.check(key, values: values, columns: table.columns, excluding: nil)
        }

        let row = try encodeRow(values, writeLongValues: true)
        let (pageNumber, page) = try findFreeRowSpace(row.count)
        var bytes = page
        let rowNumber = addDataPageRow(&bytes, row: row, flags: 0)
        source.writePage(pageNumber, bytes)
        let location = RowPointer(page: pageNumber, row: UInt8(rowNumber))

        for (index, key) in zip(indexes, keys) { index.add(key, row: location) }
        lastAutoNumber = nextAutoNumber
        rowCount += 1
        try writeCounters()
        table.cachedLocations?.append(location)
        return (location, values)
    }

    func update(_ header: RowPointer, values input: [Value]) throws -> [Value] {
        var values = normalized(input)
        let (headerBytes, deleted, overflow) = try source.row(at: header)
        guard !deleted else { throw WriteError.rowNotFound }
        var final = header
        var bytes = headerBytes
        var overflows = overflow
        var hops = 0
        while overflows {
            guard bytes.count >= 4, hops < 16 else { throw EngineError.corruptRow("bad overflow pointer") }
            final = RowPointer(raw: bytes.u32(0))
            (bytes, _, overflows) = try source.row(at: final)
            hops += 1
        }
        let decoder = RowDecoder(database: table.database, definition: definition)
        let oldValues = try decoder.decode(bytes)
        let oldFields = try decoder.split(bytes)
        let columns = definition.columns
        var reuse: [Int: [UInt8]] = [:]
        for (i, column) in columns.enumerated() {
            if column.isAutoNumber || column.type == .complex { values[i] = oldValues[i] }
            if column.type.isLongValue, values[i] == oldValues[i], let raw = oldFields[i] { reuse[i] = raw }
        }

        _ = try encodeRow(values, writeLongValues: false, reuse: reuse, minimumSize: bytes.count)
        let indexes = try editableIndexes()
        let oldKeys = try indexKeys(for: oldValues)
        let newKeys = try indexKeys(for: values)
        for (i, index) in indexes.enumerated() where oldKeys[i] != newKeys[i] {
            try index.check(newKeys[i], values: values, columns: table.columns, excluding: header)
        }

        let row = try encodeRow(values, writeLongValues: true, reuse: reuse, minimumSize: bytes.count)
        if row.count <= bytes.count {
            var page = try source.page(final.page)
            let bounds = source.rowBounds(page, row: Int(final.row))
            page.replaceSubrange(bounds.start..<bounds.start + row.count, with: row)
            source.writePage(final.page, page)
        } else {
            // Write the row elsewhere, flagged deleted so scans skip it, and
            // point the header row at it.
            let (pageNumber, page) = try findFreeRowSpace(row.count)
            var target = page
            let rowNumber = addDataPageRow(&target, row: row, flags: Self.deletedFlag)
            source.writePage(pageNumber, target)

            var headerPage = try source.page(header.page)
            let bounds = source.rowBounds(headerPage, row: Int(header.row))
            guard bounds.end - bounds.start >= 4 else { throw EngineError.corruptRow("header row too short to overflow") }
            for i in bounds.start..<bounds.end { headerPage[i] = 0 }
            headerPage[bounds.start] = UInt8(rowNumber)
            headerPage[bounds.start + 1] = UInt8(pageNumber & 0xFF)
            headerPage[bounds.start + 2] = UInt8(pageNumber >> 8 & 0xFF)
            headerPage[bounds.start + 3] = UInt8(pageNumber >> 16 & 0xFF)
            let slot = rowCountOffset + 2 + Int(header.row) * 2
            headerPage.putU16(headerPage.u16(slot) | Self.overflowFlag, at: slot)
            source.writePage(header.page, headerPage)
        }

        for (i, index) in indexes.enumerated() where oldKeys[i] != newKeys[i] {
            index.remove(oldKeys[i], row: header)
            index.add(newKeys[i], row: header)
        }
        return values
    }

    func delete(_ header: RowPointer) throws {
        if definition.columns.contains(where: { $0.type == .complex }) {
            throw WriteError.unsupported("Deleting records from tables with attachment or multi-value fields")
        }
        let (_, deleted, _) = try source.row(at: header)
        if deleted { return }
        let values = try table.row(at: header)
        let indexes = try editableIndexes()
        let keys = try indexKeys(for: values)

        var page = try source.page(header.page)
        let slot = rowCountOffset + 2 + Int(header.row) * 2
        page.putU16(page.u16(slot) | Self.deletedFlag | Self.overflowFlag, at: slot)
        source.writePage(header.page, page)

        for (index, key) in zip(indexes, keys) { index.remove(key, row: header) }
        rowCount -= 1
        try writeCounters()
        table.cachedLocations?.removeAll { $0 == header }
    }

    private func normalized(_ input: [Value]) -> [Value] {
        let count = definition.columns.count
        var values = Array(input.prefix(count))
        if values.count < count { values.append(contentsOf: repeatElement(.null, count: count - values.count)) }
        for (i, column) in definition.columns.enumerated() where column.type == .boolean && values[i].isNull {
            values[i] = .boolean(false)
        }
        return values
    }

    private func writeCounters() throws {
        var tdef = try source.page(definition.page)
        tdef.putU32(UInt32(truncatingIfNeeded: rowCount), at: layout.tdefNumRowsOffset)
        tdef.putU32(UInt32(bitPattern: lastAutoNumber), at: 20)
        if let offset = complexAutoNumberOffset {
            tdef.putU32(UInt32(bitPattern: lastComplexAutoNumber), at: offset)
        }
        source.writePage(definition.page, tdef)
    }

    // MARK: Encoding

    /// Encodes a row. Long values that fit are stored in the row; larger
    /// ones go to long value pages, but only when `writeLongValues` is set
    /// (otherwise a placeholder header stands in, to check the row fits).
    private func encodeRow(_ values: [Value], writeLongValues: Bool,
                           reuse: [Int: [UInt8]] = [:], minimumSize: Int = 0) throws -> [UInt8] {
        let columns = definition.columns
        var variable: [Int: [UInt8]] = [:]
        var longValues: [Int: [UInt8]] = [:]
        for (i, column) in columns.enumerated() where !column.isFixedLength && !values[i].isNull {
            if let raw = reuse[i] {
                variable[i] = raw
            } else if column.type.isLongValue {
                longValues[i] = try encoder.longValueData(values[i], column: column)
            } else {
                variable[i] = try encoder.inlineVariableBytes(values[i], column: column)
            }
        }
        if longValues.isEmpty { return try encoder.encode(values: values, variable: variable, minimumSize: minimumSize) }

        // Try with small long values in the row; if the row is then too
        // large, move them all out.
        let placeholder = [UInt8](repeating: 0, count: RowEncoder.longValueHeaderSize)
        for inline in [true, false] {
            func staysInRow(_ data: [UInt8]) -> Bool { inline && data.count <= RowEncoder.maxInlineLongValue }
            var trial = variable
            for (i, data) in longValues {
                trial[i] = staysInRow(data) ? Self.inlineLongValue(data) : placeholder
            }
            let measured: [UInt8]
            do {
                measured = try encoder.encode(values: values, variable: trial, minimumSize: minimumSize)
            } catch WriteError.rowTooLarge where inline {
                continue
            }
            guard writeLongValues else { return measured }
            for (i, data) in longValues.sorted(by: { $0.key < $1.key }) where !staysInRow(data) {
                trial[i] = try writeLongValue(data, column: columns[i])
            }
            return try encoder.encode(values: values, variable: trial, minimumSize: minimumSize)
        }
        throw WriteError.rowTooLarge(RowEncoder.maxRowSize + 1)
    }

    static func inlineLongValue(_ data: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: RowEncoder.longValueHeaderSize)
        header.putU32(UInt32(data.count) | 0x8000_0000, at: 0)
        return header + data
    }

    // MARK: Data pages

    private func rowFits(_ size: Int, on page: [UInt8]) -> Bool {
        page[0] == PageType.data.rawValue && size + 2 <= Int(page.u16(2))
            && Int(page.u16(rowCountOffset)) < Self.maxRowsPerPage
    }

    /// Adds `row` to a data page, below the rows already there, and returns
    /// its row number.
    private func addDataPageRow(_ page: inout [UInt8], row: [UInt8], flags: UInt16) -> Int {
        page.putU16(page.u16(2) - UInt16(row.count + 2), at: 2)
        let count = Int(page.u16(rowCountOffset))
        page.putU16(UInt16(count + 1), at: rowCountOffset)
        let end = count == 0 ? layout.pageSize : Int(page.u16(rowCountOffset + 2 + (count - 1) * 2) & 0x1FFF)
        let start = end - row.count
        page.putU16(UInt16(start) | flags, at: rowCountOffset + 2 + count * 2)
        page.replaceSubrange(start..<end, with: row)
        return count
    }

    /// A page of this table with room for a row of `size` bytes: the page
    /// the last insert used, else the last owned page with free space, else
    /// a new page.
    private func findFreeRowSpace(_ size: Int) throws -> (UInt32, [UInt8]) {
        var candidate = insertPage
        if candidate == nil {
            candidate = owned.sortedPages.reversed().first { number in
                guard free.contains(number), number < source.pageCount, let page = try? source.page(number) else { return false }
                return page[0] == PageType.data.rawValue && page.u32(4) == definition.page
            }
        }
        if let candidate {
            let page = try source.page(candidate)
            if rowFits(size, on: page) { return (candidate, page) }
            try free.remove(candidate)
        }
        let number = try source.allocatePage()
        var page = [UInt8](repeating: 0, count: layout.pageSize)
        page[0] = PageType.data.rawValue
        page[1] = 0x01
        page.putU16(UInt16(layout.pageSize - 14), at: 2)
        page.putU32(definition.page, at: 4)
        source.writePage(number, page)
        try owned.add(number)
        try free.add(number)
        insertPage = number
        return (number, page)
    }

    // MARK: Long values

    /// Where a column's long values go: per-column page maps in newer files,
    /// otherwise a page shared by the table for this session.
    private final class LongValuePages {
        let owned: UsageMapEditor?
        let free: UsageMapEditor?
        var current: UInt32?
        init(owned: UsageMapEditor?, free: UsageMapEditor?) {
            self.owned = owned
            self.free = free
        }
    }

    private func longValuePages(for column: Column) throws -> LongValuePages {
        let key = definition.longValueMaps[column.number] == nil ? -1 : column.number
        if let pages = longValuePages[key] { return pages }
        let pages: LongValuePages
        if let maps = definition.longValueMaps[column.number] {
            pages = LongValuePages(owned: try UsageMapEditor(source: source, pointer: maps.owned),
                                   free: try UsageMapEditor(source: source, pointer: maps.free))
        } else {
            pages = LongValuePages(owned: nil, free: nil)
        }
        longValuePages[key] = pages
        return pages
    }

    private func longValuePage(_ pages: LongValuePages, for length: Int) throws -> UInt32 {
        let length = min(length, Self.maxLongValueRow)
        if let current = pages.current, rowFits(length, on: try source.page(current)) { return current }
        if let owned = pages.owned, let free = pages.free {
            let last = owned.sortedPages.reversed().first { number in
                guard free.contains(number), number < source.pageCount, let page = try? source.page(number) else { return false }
                return page[0] == PageType.data.rawValue
            }
            if let last {
                if rowFits(length, on: try source.page(last)) {
                    pages.current = last
                    return last
                }
                try free.remove(last)
            }
        }
        let number = try source.allocatePage()
        var page = [UInt8](repeating: 0, count: layout.pageSize)
        page[0] = PageType.data.rawValue
        page[1] = 0x01
        page.putU16(UInt16(layout.pageSize - 14), at: 2)
        page.replaceSubrange(4..<8, with: Array("LVAL".utf8))
        source.writePage(number, page)
        try pages.owned?.add(number)
        try pages.free?.add(number)
        pages.current = number
        return number
    }

    private func discardCurrent(_ pages: LongValuePages) throws {
        if let current = pages.current { try pages.free?.remove(current) }
        pages.current = nil
    }

    /// Writes `data` to long value pages and returns the 12-byte header the
    /// row stores.
    private func writeLongValue(_ data: [UInt8], column: Column) throws -> [UInt8] {
        let pages = try longValuePages(for: column)
        var header = [UInt8](repeating: 0, count: RowEncoder.longValueHeaderSize)
        let first: RowPointer
        if data.count <= Self.maxLongValueRow {
            header.putU32(UInt32(data.count) | 0x4000_0000, at: 0)
            let number = try longValuePage(pages, for: data.count)
            var page = try source.page(number)
            let row = addDataPageRow(&page, row: data, flags: 0)
            source.writePage(number, page)
            first = RowPointer(page: number, row: UInt8(row))
        } else {
            header.putU32(UInt32(data.count), at: 0)
            var number = try longValuePage(pages, for: data.count)
            first = RowPointer(page: number, row: UInt8(source.rowCount(onDataPage: try source.page(number))))
            var position = 0
            while position < data.count {
                let chunk = min(Self.maxLongValueRow - 4, data.count - position)
                var next = RowPointer(page: 0, row: 0)
                if position + chunk < data.count {
                    try discardCurrent(pages)
                    let nextNumber = try longValuePage(pages, for: data.count - position - chunk + 4)
                    next = RowPointer(page: nextNumber, row: UInt8(source.rowCount(onDataPage: try source.page(nextNumber))))
                }
                var row: [UInt8] = [next.row, UInt8(next.page & 0xFF), UInt8(next.page >> 8 & 0xFF), UInt8(next.page >> 16 & 0xFF)]
                row.append(contentsOf: data[position..<position + chunk])
                var page = try source.page(number)
                _ = addDataPageRow(&page, row: row, flags: 0)
                source.writePage(number, page)
                position += chunk
                number = next.page
            }
        }
        header[4] = first.row
        header[5] = UInt8(first.page & 0xFF)
        header[6] = UInt8(first.page >> 8 & 0xFF)
        header[7] = UInt8(first.page >> 16 & 0xFF)
        return header
    }

    // MARK: Indexes

    private func editableIndexes() throws -> [EditableIndex] {
        if let loadedIndexes { return loadedIndexes }
        var result: [EditableIndex] = []
        let reader = IndexReader(source: source)
        for physical in 0..<definition.realIndexCount {
            let logical = definition.indexes.filter { $0.physicalIndex == physical }
            guard let first = logical.first else { continue }
            let isPrimary = logical.contains { $0.kind == .primaryKey }
            result.append(EditableIndex(
                name: first.name, index: first, physical: physical,
                isUnique: isPrimary || first.flags & 0x01 != 0, isPrimary: isPrimary,
                entries: try reader.entries(root: first.rootPage)))
        }
        loadedIndexes = result
        return result
    }

    private func indexKeys(for values: [Value]) throws -> [[UInt8]] {
        let keyEncoder = IndexKeyEncoder(format: table.database.format)
        return try editableIndexes().map { try keyEncoder.key(for: $0.index, columns: table.columns, row: values) }
    }

    /// Rebuilds changed index trees and records their entry counts.
    func flush() throws {
        guard let loadedIndexes else { return }
        var tdef = try source.page(definition.page)
        var changed = false
        for index in loadedIndexes where index.isDirty {
            let pagesMap = index.index.pagesMap.isNull ? nil
                : try UsageMapEditor(source: source, pointer: index.index.pagesMap)
            try IndexTreeWriter(source: source, tableDefinitionPage: definition.page)
                .rebuild(root: index.index.rootPage, entries: index.entries, pagesMap: pagesMap)
            index.isDirty = false
            tdef = try source.page(definition.page)
            let offset = layout.tdefColumnsStart + index.physical * layout.realIndexEntrySize + 4
            tdef.putU32(UInt32(index.uniqueKeyCount), at: offset)
            changed = true
        }
        if changed { source.writePage(definition.page, tdef) }
    }
}

/// An index's entries held in memory while a table is edited, in the order
/// Access sorts them: by key bytes, then by row.
final class EditableIndex {
    let name: String
    let index: Index
    let physical: Int
    let isUnique: Bool
    let isPrimary: Bool
    private(set) var entries: [IndexEntry]
    var isDirty = false

    init(name: String, index: Index, physical: Int, isUnique: Bool, isPrimary: Bool, entries: [IndexEntry]) {
        self.name = name
        self.index = index
        self.physical = physical
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.entries = entries.sorted(by: Self.precedes)
    }

    static func precedes(_ a: IndexEntry, _ b: IndexEntry) -> Bool {
        if a.key != b.key { return a.key.lexicographicallyPrecedes(b.key) }
        if a.row.page != b.row.page { return a.row.page < b.row.page }
        return a.row.row < b.row.row
    }

    private func nullCount(_ values: [Value], columns: [Column]) -> Int {
        index.columns.filter { key in
            guard let i = columns.firstIndex(where: { $0.number == key.number }) else { return false }
            return values[i].isNull
        }.count
    }

    private func skips(_ values: [Value], columns: [Column]) -> Bool {
        index.ignoresNulls && nullCount(values, columns: columns) == index.columns.count
    }

    /// Throws if adding `key` would break a constraint. `excluding` is the
    /// row being updated, whose old entry doesn't count.
    func check(_ key: [UInt8], values: [Value], columns: [Column], excluding: RowPointer?) throws {
        if skips(values, columns: columns) { return }
        let nulls = nullCount(values, columns: columns)
        if nulls > 0, isPrimary || index.isRequired {
            let missing = index.columns.compactMap { key in columns.firstIndex { $0.number == key.number } }
                .first { values[$0].isNull }
            throw WriteError.requiredValueMissing(missing.map { columns[$0].name } ?? name)
        }
        guard isUnique, nulls < index.columns.count else { return }
        var i = lowerBound(key)
        while i < entries.count, entries[i].key == key {
            if entries[i].row != excluding { throw WriteError.duplicateKey(index: name) }
            i += 1
        }
    }

    func add(_ key: [UInt8], row: RowPointer) {
        let entry = IndexEntry(key: key, row: row)
        entries.insert(entry, at: insertionPoint(entry))
        isDirty = true
    }

    func remove(_ key: [UInt8], row: RowPointer) {
        let entry = IndexEntry(key: key, row: row)
        let i = insertionPoint(entry)
        if i < entries.count, entries[i] == entry {
            entries.remove(at: i)
            isDirty = true
        } else if let j = entries.firstIndex(where: { $0.row == row }) {
            // The stored key differs from ours (for example an entry written
            // with another collation); drop it by row.
            entries.remove(at: j)
            isDirty = true
        }
    }

    var uniqueKeyCount: Int {
        var count = 0
        var previous: [UInt8]?
        for entry in entries where entry.key != previous {
            count += 1
            previous = entry.key
        }
        return count
    }

    private func lowerBound(_ key: [UInt8]) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].key.lexicographicallyPrecedes(key) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func insertionPoint(_ entry: IndexEntry) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if Self.precedes(entries[mid], entry) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

extension Array where Element == UInt8 {
    mutating func putU16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8(value >> 8)
    }

    mutating func putU32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(i))) }
    }
}
