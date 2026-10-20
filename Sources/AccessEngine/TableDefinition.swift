/// A parsed table definition (TDEF), which may span several pages.
struct TableDefinition {
    let page: UInt32
    let rowCount: Int
    let isSystem: Bool
    let numVarColumns: Int
    let columns: [Column]
    let indexes: [Index]
    let usageMap: RowPointer
    let freeMap: RowPointer
    /// The highest column number ever used plus one: the size of every row's
    /// null mask.
    let maxColumnCount: Int
    let realIndexCount: Int
    /// Per-column page maps for long values (ACE), keyed by column number.
    let longValueMaps: [Int: (owned: RowPointer, free: RowPointer)]

    init(page: UInt32, source: PageSource) throws {
        let layout = source.layout
        var buffer = try source.page(page)
        guard buffer[0] == PageType.tableDefinition.rawValue else {
            throw EngineError.corruptPage(page, "expected a table definition page")
        }
        // Continuation pages each carry an 8-byte header that is not part of
        // the definition.
        var next = buffer.u32(4)
        var seen: Set<UInt32> = [page]
        while next != 0, !seen.contains(next) {
            seen.insert(next)
            let more = try source.page(next)
            buffer.append(contentsOf: more[8...])
            next = more.u32(4)
        }
        self.page = page
        let codec = TextCodec(format: source.header.format, codePage: source.header.codePage)

        rowCount = Int(buffer.u32(layout.tdefNumRowsOffset))
        isSystem = buffer[layout.tdefTableTypeOffset] == 0x53
        numVarColumns = Int(buffer.u16(layout.tdefNumVarColsOffset))
        maxColumnCount = Int(buffer.u16(layout.tdefMaxColsOffset))
        let numColumns = Int(buffer.u16(layout.tdefNumColsOffset))
        let numIndexes = Int(buffer.u32(layout.tdefNumIndexesOffset))
        let numRealIndexes = Int(buffer.u32(layout.tdefNumRealIndexesOffset))
        realIndexCount = numRealIndexes
        usageMap = RowPointer(raw: buffer.u32(layout.tdefUsageMapOffset))
        freeMap = RowPointer(raw: buffer.u32(layout.tdefFreeMapOffset))

        var offset = layout.tdefColumnsStart + numRealIndexes * layout.realIndexEntrySize
        let columnEntries = offset
        offset += numColumns * layout.columnEntrySize
        guard offset <= buffer.count else {
            throw EngineError.corruptPage(page, "column entries run past the definition")
        }

        var names: [String] = []
        for _ in 0..<numColumns {
            let (name, size) = codec.readName(buffer, at: offset)
            names.append(name)
            offset += size
        }

        var columns: [Column] = []
        for n in 0..<numColumns {
            let e = columnEntries + n * layout.columnEntrySize
            guard let type = ColumnType(rawValue: buffer[e]) else {
                throw EngineError.corruptPage(page, "unknown column type 0x\(String(buffer[e], radix: 16))")
            }
            columns.append(Column(
                name: names[n], type: type,
                number: Int(buffer.u16(e + layout.colNumberOffset)),
                variableIndex: Int(buffer.u16(e + layout.colVarIndexOffset)),
                fixedOffset: Int(buffer.u16(e + layout.colFixedOffsetOffset)),
                length: Int(buffer.u16(e + layout.colLengthOffset)),
                precision: Int(buffer[e + layout.colPrecisionOffset]),
                scale: Int(buffer[e + layout.colScaleOffset]),
                flags: buffer[e + layout.colFlagsOffset],
                extFlags: layout.colExtFlagsOffset.map { buffer[e + $0] } ?? 0,
                sortOrder: Self.sortOrder(buffer, entry: e, format: source.header.format)))
        }
        self.columns = columns.sorted { $0.number < $1.number }

        // Physical ("real") index definitions: up to ten key columns each.
        struct RealIndex { var columns: [(Int, Bool)]; var pages: RowPointer; var root: UInt32; var flags: UInt8 }
        var realIndexes: [RealIndex] = []
        for _ in 0..<numRealIndexes {
            guard offset + layout.realIndexDefSize <= buffer.count else { break }
            var keys: [(Int, Bool)] = []
            var p = offset + layout.realIndexDefLeadIn
            for _ in 0..<10 {
                let number = buffer.u16(p)
                if number != 0xFFFF { keys.append((Int(number), buffer[p + 2] & 0x01 != 0)) }
                p += 3
            }
            // The index's usage map, then its root page, then its flags.
            let root = buffer.u32(p + 4)
            realIndexes.append(RealIndex(columns: keys, pages: RowPointer(raw: buffer.u32(p)), root: root, flags: buffer[p + 8]))
            offset += layout.realIndexDefSize
        }

        struct LogicalIndex { var real: Int; var type: UInt8 }
        var logical: [LogicalIndex] = []
        for _ in 0..<numIndexes {
            guard offset + layout.logicalIndexSize <= buffer.count else { break }
            let p = offset + layout.logicalIndexLeadIn
            logical.append(LogicalIndex(real: Int(buffer.u32(p + 4)), type: buffer[p + 19]))
            offset += layout.logicalIndexSize
        }
        var indexes: [Index] = []
        for entry in logical {
            guard offset < buffer.count else { break }
            let (name, size) = codec.readName(buffer, at: offset)
            offset += size
            guard entry.real < realIndexes.count else { continue }
            let real = realIndexes[entry.real]
            let kind: Index.Kind = entry.type == 1 ? .primaryKey : entry.type == 2 ? .foreignKey : .normal
            indexes.append(Index(
                name: name, kind: kind,
                columns: real.columns.map { (number: $0.0, ascending: $0.1) },
                isUnique: real.flags & 0x01 != 0 || kind == .primaryKey,
                ignoresNulls: real.flags & 0x02 != 0,
                isRequired: real.flags & 0x08 != 0,
                rootPage: real.root, physicalIndex: entry.real, pagesMap: real.pages, flags: real.flags))
        }
        self.indexes = indexes

        var longValueMaps: [Int: (owned: RowPointer, free: RowPointer)] = [:]
        while offset + 10 <= buffer.count {
            let number = buffer.u16(offset)
            if number == 0xFFFF { break }
            longValueMaps[Int(number)] = (RowPointer(raw: buffer.u32(offset + 2)), RowPointer(raw: buffer.u32(offset + 6)))
            offset += 10
        }
        self.longValueMaps = longValueMaps
    }
}

extension TableDefinition {
    /// Jet 4 and later store a 2-byte collation value and, three bytes in, a
    /// version. A zero value means the format's default.
    static func sortOrder(_ buffer: [UInt8], entry: Int, format: FileFormat) -> SortOrder {
        let fallback: SortOrder
        switch format {
        case .jet3: fallback = SortOrder(value: 1033, version: 0xFF)
        case .jet4, .ace12: fallback = .generalLegacy
        default: fallback = .general
        }
        let value = buffer.u16(entry + (format.isJet3 ? 9 : 11))
        if value == 0 { return fallback }
        if format.isJet3 { return SortOrder(value: value, version: 0xFF) }
        return SortOrder(value: value, version: buffer[entry + 14])
    }
}

/// A usage map: the set of pages owned by a table, stored either inline as a
/// bitmap or as a list of bitmap pages.
enum UsageMap {
    static func pages(at pointer: RowPointer, source: PageSource) throws -> [UInt32] {
        let (map, _, _) = try source.row(at: pointer)
        guard !map.isEmpty else { return [] }
        var pages: [UInt32] = []
        switch map[0] {
        case 0x00:
            guard map.count >= 5 else { return [] }
            let start = map.u32(1)
            appendBits(map, from: 5, base: start, into: &pages)
        case 0x01:
            let bitsPerPage = UInt32((source.layout.pageSize - 4) * 8)
            var i = 1
            var mapIndex: UInt32 = 0
            while i + 4 <= map.count {
                let mapPage = map.u32(i)
                if mapPage != 0 {
                    let bitmap = try source.page(mapPage)
                    guard bitmap[0] == PageType.usageMap.rawValue else {
                        throw EngineError.corruptPage(mapPage, "expected a usage map page")
                    }
                    appendBits(bitmap, from: 4, base: mapIndex * bitsPerPage, into: &pages)
                }
                i += 4
                mapIndex += 1
            }
        default:
            throw EngineError.corruptRow("unknown usage map type \(map[0])")
        }
        return pages
    }

    private static func appendBits(_ bytes: [UInt8], from offset: Int, base: UInt32, into pages: inout [UInt32]) {
        guard offset < bytes.count else { return }
        for i in offset..<bytes.count where bytes[i] != 0 {
            let byte = bytes[i]
            for bit in 0..<8 where byte & (1 << bit) != 0 {
                pages.append(base + UInt32((i - offset) * 8 + bit))
            }
        }
    }
}
