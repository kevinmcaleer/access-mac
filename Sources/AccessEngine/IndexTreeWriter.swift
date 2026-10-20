// Writing index B-trees. After edits an index is rebuilt from its sorted
// entries: leaves packed in order, then node levels above them, with the
// root kept on its original page. Page layout follows Jackcess's IndexData
// and IndexPageCache (Apache License 2.0).

struct IndexTreeWriter {
    let source: PageSource
    let tableDefinitionPage: UInt32

    private var pageSize: Int { source.layout.pageSize }
    private static let prefixLengthOffset = 24
    private static let maskOffset = 27
    private static let maskSize = 453
    private static let entriesStart = maskOffset + maskSize
    private var maxEntrySpace: Int { pageSize - Self.entriesStart }

    /// One page to write: leaf entries or child pages, plus its links.
    private struct PlannedPage {
        var range: Range<Int>
        /// The last leaf entry under this page, which its parent records.
        var last: IndexEntry?
        var number: UInt32 = 0
    }

    func rebuild(root: UInt32, entries: [IndexEntry], pagesMap: UsageMapEditor?) throws {
        let oldPages = try treePages(root: root)

        // Plan levels bottom-up until one page remains.
        var levels: [[PlannedPage]] = []
        let leafSizes = entries.map { $0.key.count + 4 }
        let leafRanges = pack(count: entries.count, size: { leafSizes[$0] }, key: { entries[$0].key })
        levels.append(leafRanges.map { PlannedPage(range: $0, last: $0.isEmpty ? nil : entries[$0.upperBound - 1]) })
        while levels[levels.count - 1].count > 1 {
            let children = levels[levels.count - 1]
            let ranges = pack(count: children.count, size: { children[$0].last!.key.count + 8 },
                              key: { children[$0].last!.key })
            levels.append(ranges.map { PlannedPage(range: $0, last: children[$0.upperBound - 1].last) })
        }

        // Number the pages: the root keeps its page, the others reuse the
        // old tree's pages and then new ones.
        var pool = oldPages.filter { $0 != root }.sorted()
        pool.reverse()
        for level in 0..<levels.count {
            for i in levels[level].indices {
                if level == levels.count - 1 {
                    levels[level][i].number = root
                } else if let reused = pool.popLast() {
                    levels[level][i].number = reused
                } else {
                    let number = try source.allocatePage()
                    try pagesMap?.add(number)
                    levels[level][i].number = number
                }
            }
        }
        for leftover in pool { try source.deallocatePage(leftover) }

        for (level, pages) in levels.enumerated() {
            let isTop = level == levels.count - 1
            // Leaves link end to end; node pages only to siblings under the
            // same parent.
            var parentOf: [Int] = Array(repeating: 0, count: pages.count)
            if !isTop {
                for (p, parent) in levels[level + 1].enumerated() {
                    for i in parent.range { parentOf[i] = p }
                }
            }
            for (i, page) in pages.enumerated() {
                var previous: UInt32 = 0, next: UInt32 = 0
                if !isTop {
                    let linked = level == 0
                    if i > 0, linked || parentOf[i - 1] == parentOf[i] { previous = pages[i - 1].number }
                    if i + 1 < pages.count, linked || parentOf[i + 1] == parentOf[i] { next = pages[i + 1].number }
                }
                if level == 0 {
                    let items = entries[page.range].map { (key: $0.key, tail: Self.rowBytes($0.row)) }
                    try write(page.number, isLeaf: true, previous: previous, next: next, childTail: 0, items: items)
                } else {
                    let children = levels[level - 1][page.range]
                    var items = children.map { child in
                        (key: child.last!.key, tail: Self.rowBytes(child.last!.row) + Self.bigEndian(child.number))
                    }
                    var tail: UInt32 = 0
                    if items.count > 1 {
                        // The last child is recorded as the page's tail
                        // rather than as an entry.
                        items.removeLast()
                        tail = children.last!.number
                    }
                    try write(page.number, isLeaf: false, previous: previous, next: next, childTail: tail, items: items)
                }
            }
        }
    }

    /// Every page of the existing tree.
    private func treePages(root: UInt32) throws -> Set<UInt32> {
        let reader = IndexReader(source: source)
        var seen: Set<UInt32> = []
        var queue = [root]
        while let number = queue.popLast() {
            guard !seen.contains(number), number < source.pageCount else { continue }
            seen.insert(number)
            guard let page = try? reader.readPage(number), !page.isLeaf else { continue }
            queue.append(contentsOf: page.children)
            if page.childTail != 0 { queue.append(page.childTail) }
        }
        return seen
    }

    /// Splits `count` entries into runs that each fit on a page, given each
    /// entry's size and its key (keys on a page share a stored prefix).
    private func pack(count: Int, size: (Int) -> Int, key: (Int) -> [UInt8]) -> [Range<Int>] {
        guard count > 0 else { return [0..<0] }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count {
            var end = start + 1
            var total = size(start)
            let first = key(start)
            while end < count {
                let candidate = total + size(end)
                let prefix = Self.commonPrefix(first, key(end))
                if candidate - (end - start) * prefix > maxEntrySpace { break }
                total = candidate
                end += 1
            }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    private func write(_ number: UInt32, isLeaf: Bool, previous: UInt32, next: UInt32, childTail: UInt32,
                       items: [(key: [UInt8], tail: [UInt8])]) throws {
        var page = [UInt8](repeating: 0, count: pageSize)
        page[0] = isLeaf ? PageType.indexLeaf.rawValue : PageType.indexIntermediate.rawValue
        page[1] = 0x01
        page.putU32(tableDefinitionPage, at: 4)
        page.putU32(previous, at: 12)
        page.putU32(next, at: 16)
        page.putU32(childTail, at: 20)

        // The prefix comes from the keys of the first and last entries.
        var prefix: [UInt8] = []
        if let first = items.first, let last = items.last {
            prefix = Array(first.key.prefix(Self.commonPrefix(first.key, last.key)))
        }
        page.putU16(UInt16(prefix.count), at: Self.prefixLengthOffset)

        var data = prefix
        var total = prefix.count
        for item in items {
            data.append(contentsOf: item.key[prefix.count...])
            data.append(contentsOf: item.tail)
            total += item.key.count + item.tail.count - prefix.count
            page[Self.maskOffset + total / 8] |= 1 << (total % 8)
        }
        guard data.count <= maxEntrySpace else {
            throw EngineError.corruptPage(number, "index page overflow while writing")
        }
        page.replaceSubrange(Self.entriesStart..<Self.entriesStart + data.count, with: data)
        page.putU16(UInt16(pageSize - Self.entriesStart - data.count), at: 2)
        source.writePage(number, page)
    }

    static func commonPrefix(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var n = 0
        let limit = min(a.count, b.count)
        while n < limit, a[n] == b[n] { n += 1 }
        return n
    }

    static func rowBytes(_ row: RowPointer) -> [UInt8] {
        [UInt8(row.page >> 16 & 0xFF), UInt8(row.page >> 8 & 0xFF), UInt8(row.page & 0xFF), row.row]
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}
