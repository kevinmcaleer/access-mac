/// One leaf entry of an index: the encoded key and the row it points to.
public struct IndexEntry: Hashable, Sendable {
    public let key: [UInt8]
    public let row: RowPointer
}

/// Reads index B-trees. Entry headers are little-endian but the entries
/// themselves (keys and row pointers) are big-endian, so they sort as bytes.
struct IndexReader {
    let source: PageSource

    private var jet3: Bool { source.header.format.isJet3 }
    private var prefixLengthOffset: Int { jet3 ? 20 : 24 }
    private var maskOffset: Int { jet3 ? 22 : 27 }
    private var maskSize: Int { jet3 ? 226 : 453 }
    private var prevOffset: Int { jet3 ? 8 : 12 }
    private var nextOffset: Int { jet3 ? 12 : 16 }
    private var tailOffset: Int { jet3 ? 16 : 20 }

    struct Page {
        let number: UInt32
        let isLeaf: Bool
        let previous: UInt32
        let next: UInt32
        let childTail: UInt32
        /// For leaves, entries; for nodes, entries plus the child page each
        /// one leads to.
        let entries: [IndexEntry]
        let children: [UInt32]
    }

    func readPage(_ number: UInt32) throws -> Page {
        let page = try source.page(number)
        guard page[0] == PageType.indexLeaf.rawValue || page[0] == PageType.indexIntermediate.rawValue else {
            throw EngineError.corruptPage(number, "expected an index page")
        }
        let isLeaf = page[0] == PageType.indexLeaf.rawValue
        let prefixLength = Int(page.u16(prefixLengthOffset))
        let entriesStart = maskOffset + maskSize
        var entries: [IndexEntry] = []
        var children: [UInt32] = []
        var prefix: [UInt8] = []
        var lastEnd = 0
        for i in 0..<maskSize where page[maskOffset + i] != 0 {
            for bit in 0..<8 where page[maskOffset + i] & (1 << bit) != 0 {
                let end = i * 8 + bit
                let start = entriesStart + lastEnd
                let stop = entriesStart + end
                guard stop <= page.count, start <= stop else {
                    throw EngineError.corruptPage(number, "index entry runs off the page")
                }
                let stored = Array(page[start..<stop])
                let full = entries.isEmpty ? stored : prefix + stored
                if entries.isEmpty, prefixLength > 0 { prefix = Array(stored.prefix(prefixLength)) }
                let trailing = isLeaf ? 4 : 8
                guard full.count >= trailing else { throw EngineError.corruptPage(number, "short index entry") }
                let keyEnd = full.count - trailing
                let pageNumber = UInt32(full[keyEnd]) << 16 | UInt32(full[keyEnd + 1]) << 8 | UInt32(full[keyEnd + 2])
                entries.append(IndexEntry(key: Array(full[..<keyEnd]),
                                          row: RowPointer(page: pageNumber, row: full[keyEnd + 3])))
                if !isLeaf {
                    let c = keyEnd + 4
                    children.append(UInt32(full[c]) << 24 | UInt32(full[c + 1]) << 16 | UInt32(full[c + 2]) << 8 | UInt32(full[c + 3]))
                }
                lastEnd = end
            }
        }
        return Page(number: number, isLeaf: isLeaf, previous: page.u32(prevOffset), next: page.u32(nextOffset),
                    childTail: page.u32(tailOffset), entries: entries, children: children)
    }

    /// Every leaf entry, in key order: descend to the leftmost leaf, then
    /// follow the leaf chain.
    func entries(root: UInt32) throws -> [IndexEntry] {
        var page = try readPage(root)
        var depth = 0
        while !page.isLeaf {
            guard let first = page.children.first ?? (page.childTail != 0 ? page.childTail : nil), depth < 32 else {
                return []
            }
            page = try readPage(first)
            depth += 1
        }
        var result = page.entries
        var seen: Set<UInt32> = [page.number]
        while page.next != 0, !seen.contains(page.next) {
            seen.insert(page.next)
            page = try readPage(page.next)
            result.append(contentsOf: page.entries)
        }
        return result
    }
}

extension Table {
    /// The entries of `index`, in index order.
    public func entries(of index: Index) throws -> [IndexEntry] {
        try IndexReader(source: database.source).entries(root: index.rootPage)
    }

    /// The key `index` would store for `row`.
    public func indexKey(_ index: Index, for row: [Value]) throws -> [UInt8] {
        try IndexKeyEncoder(format: database.format).key(for: index, columns: columns, row: row)
    }
}
