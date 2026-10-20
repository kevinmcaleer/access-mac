// Editing usage maps: the bitmaps of pages a table (or the database's free
// space) owns. Ported from Jackcess's UsageMap (Apache License 2.0), which
// mirrors how Access grows and promotes maps.

/// A usage map loaded for editing. Inline maps keep a start page and a
/// bitmap inside their row; reference maps list bitmap pages that each cover
/// a fixed range of page numbers.
final class UsageMapEditor {
    private unowned let source: PageSource
    private let mapPage: UInt32
    private let rowStart: Int
    private let rowEnd: Int
    private let isGlobal: Bool
    private var isReference = false
    private(set) var startPage = 0
    private(set) var endPage = 0
    private var pages: Set<Int> = []

    /// Set while the global map allocates one of its own bitmap pages.
    private var allocatingMapPage = false
    private var pendingRemoval: Int?

    private var pageSize: Int { source.layout.pageSize }
    private var bitsPerMapPage: Int { (pageSize - 4) * 8 }
    private var inlineCapacity: Int { (rowEnd - (rowStart + 5)) * 8 }

    init(source: PageSource, pointer: RowPointer, isGlobal: Bool = false) throws {
        self.source = source
        self.isGlobal = isGlobal
        mapPage = pointer.page
        let page = try source.page(pointer.page)
        let bounds = source.rowBounds(page, row: Int(pointer.row))
        rowStart = bounds.start
        rowEnd = bounds.end
        guard rowEnd - rowStart >= 5 else { throw EngineError.corruptRow("usage map row too short") }
        switch page[rowStart] {
        case 0x00:
            startPage = Int(page.u32(rowStart + 1))
            endPage = startPage + inlineCapacity
            readBits(page, from: rowStart + 5, to: rowEnd, base: startPage)
        case 0x01:
            isReference = true
            let count = (rowEnd - rowStart - 1) / 4
            startPage = 0
            endPage = count * bitsPerMapPage
            for i in 0..<count {
                let number = page.u32(rowStart + 1 + i * 4)
                guard number != 0 else { continue }
                let bitmap = try source.page(number)
                readBits(bitmap, from: 4, to: pageSize, base: i * bitsPerMapPage)
            }
        default:
            throw EngineError.corruptRow("unknown usage map type \(page[rowStart])")
        }
    }

    private func readBits(_ bytes: [UInt8], from: Int, to: Int, base: Int) {
        for i in from..<to where bytes[i] != 0 {
            for bit in 0..<8 where bytes[i] & (1 << bit) != 0 {
                pages.insert(base + (i - from) * 8 + bit)
            }
        }
    }

    var sortedPages: [UInt32] { pages.sorted().map(UInt32.init) }

    func contains(_ page: UInt32) -> Bool { pages.contains(Int(page)) }

    func add(_ page: UInt32) throws { try update(Int(page), add: true) }

    func remove(_ page: UInt32) throws { try update(Int(page), add: false) }

    private func update(_ page: Int, add: Bool) throws {
        if isReference {
            if isGlobal, allocatingMapPage, !add {
                pendingRemoval = page
                return
            }
            try updateReference(page, add: add)
            while let pending = pendingRemoval {
                pendingRemoval = nil
                try updateReference(pending, add: false)
            }
            return
        }
        if page >= startPage, page < endPage {
            try setBit(page, add: add, in: mapPage, offset: rowStart + 5, relative: page - startPage)
        } else if isGlobal {
            // Pages outside the global map's window are implicitly in use,
            // so only removals past the end need the window to move.
            if !add, pages.isEmpty || page > (pages.max() ?? 0) {
                try moveGlobalWindow(for: page)
            }
        } else if add {
            var first = pages.min() ?? page
            var last = pages.max() ?? page
            if page > last { last = page } else if page < first { first = page }
            first = first / 8 * 8
            if last - first + 1 < inlineCapacity {
                try moveWindow(to: first, adding: page)
            } else {
                try promoteToReference(adding: page)
            }
        }
    }

    private func setBit(_ page: Int, add: Bool, in mapPageNumber: UInt32, offset: Int, relative: Int) throws {
        var bytes = try source.page(mapPageNumber)
        let index = offset + relative / 8
        let mask = UInt8(1 << (relative % 8))
        if add {
            bytes[index] |= mask
            pages.insert(page)
        } else {
            bytes[index] &= ~mask
            pages.remove(page)
        }
        source.writePage(mapPageNumber, bytes)
    }

    private func clearRow(type: UInt8) throws {
        var bytes = try source.page(mapPage)
        for i in (rowStart + 1)..<rowEnd { bytes[i] = 0 }
        bytes[rowStart] = type
        source.writePage(mapPage, bytes)
        pages.removeAll()
    }

    private func moveWindow(to newStart: Int, adding newPage: Int?) throws {
        let old = pages
        try clearRow(type: 0x00)
        var bytes = try source.page(mapPage)
        let start = UInt32(newStart)
        bytes.replaceSubrange((rowStart + 1)..<(rowStart + 5),
                              with: [UInt8(start & 0xFF), UInt8(start >> 8 & 0xFF), UInt8(start >> 16 & 0xFF), UInt8(start >> 24)])
        source.writePage(mapPage, bytes)
        startPage = newStart
        endPage = newStart + inlineCapacity
        for page in old.sorted() { try update(page, add: true) }
        if let newPage { try update(newPage, add: true) }
    }

    private func moveGlobalWindow(for page: Int) throws {
        let wasEmpty = pages.isEmpty
        let oldEnd = endPage
        let newStart = (wasEmpty ? page : page - inlineCapacity / 2) / 8 * 8
        try moveWindow(to: max(0, newStart), adding: nil)
        if wasEmpty {
            var bytes = try source.page(mapPage)
            for i in (rowStart + 5)..<rowEnd { bytes[i] = 0xFF }
            source.writePage(mapPage, bytes)
            for p in startPage..<endPage { pages.insert(p) }
        } else {
            for p in max(oldEnd, startPage)..<endPage { try update(p, add: true) }
        }
        if page >= startPage, page < endPage {
            try setBit(page, add: false, in: mapPage, offset: rowStart + 5, relative: page - startPage)
        }
    }

    private func promoteToReference(adding newPage: Int) throws {
        let old = pages
        try clearRow(type: 0x01)
        isReference = true
        startPage = 0
        endPage = (rowEnd - rowStart - 1) / 4 * bitsPerMapPage
        for page in old.sorted() { try update(page, add: true) }
        try update(newPage, add: true)
    }

    private func updateReference(_ page: Int, add: Bool) throws {
        guard page >= startPage, page < endPage else { return }
        let index = page / bitsPerMapPage
        let pointerOffset = rowStart + 1 + index * 4
        var row = try source.page(mapPage)
        var bitmapPage = row.u32(pointerOffset)
        if bitmapPage == 0 {
            if isGlobal { allocatingMapPage = true }
            defer { if isGlobal { allocatingMapPage = false } }
            bitmapPage = try source.allocatePage()
            var bitmap = [UInt8](repeating: 0, count: pageSize)
            bitmap[0] = PageType.usageMap.rawValue
            bitmap[1] = 0x01
            if isGlobal {
                // A new global bitmap page starts with every page free.
                for i in 4..<pageSize { bitmap[i] = 0xFF }
                for p in (index * bitsPerMapPage)..<((index + 1) * bitsPerMapPage) { pages.insert(p) }
            }
            source.writePage(bitmapPage, bitmap)
            row = try source.page(mapPage)
            row.replaceSubrange(pointerOffset..<pointerOffset + 4,
                                with: [UInt8(bitmapPage & 0xFF), UInt8(bitmapPage >> 8 & 0xFF),
                                       UInt8(bitmapPage >> 16 & 0xFF), UInt8(bitmapPage >> 24)])
            source.writePage(mapPage, row)
        }
        try setBit(page, add: add, in: bitmapPage, offset: 4, relative: page - index * bitsPerMapPage)
    }
}
