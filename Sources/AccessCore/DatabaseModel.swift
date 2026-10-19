import AccessEngine
import Foundation

/// The groups of the navigation pane, in the order Access lists them.
public enum ObjectCategory: String, CaseIterable, Identifiable, Sendable {
    case tables = "Tables"
    case queries = "Queries"
    case forms = "Forms"
    case reports = "Reports"
    case macros = "Macros"
    case modules = "Modules"

    public var id: String { rawValue }

    /// SF Symbol for the category, as the app shows it.
    public var symbolName: String {
        switch self {
        case .tables: return "tablecells"
        case .queries: return "line.3.horizontal.decrease.circle"
        case .forms: return "rectangle.on.rectangle"
        case .reports: return "doc.richtext"
        case .macros: return "bolt"
        case .modules: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var kinds: [CatalogObject.Kind] {
        switch self {
        case .tables: return [.table, .linkedTable, .linkedODBCTable]
        case .queries: return [.query]
        case .forms: return [.form]
        case .reports: return [.report]
        case .macros: return [.macro]
        case .modules: return [.module]
        }
    }
}

/// One object in the navigation pane.
public struct DatabaseObject: Identifiable, Hashable, Sendable {
    public var id: String { "\(category.rawValue)/\(name)" }
    public let name: String
    public let category: ObjectCategory
    public let isLinked: Bool
    public let isSystem: Bool
    public let created: AccessDate?
    public let updated: AccessDate?
    /// Where a linked table points, for display.
    public let linkTarget: String?
}

/// An open database as the app sees it: the navigation pane's objects plus
/// access to table data.
public final class DatabaseModel {
    public let database: Database
    public let fileSize: Int?

    public init(database: Database, fileSize: Int? = nil) {
        self.database = database
        self.fileSize = fileSize
    }

    public convenience init(url: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        try self.init(database: Database(url: url), fileSize: size)
    }

    public convenience init(data: Data) throws {
        try self.init(database: Database(data: data), fileSize: data.count)
    }

    /// Objects in `category`, sorted by name. `search` matches anywhere in
    /// the name, ignoring case, as the navigation pane's search box does.
    public func objects(in category: ObjectCategory, search: String = "",
                        includeSystem: Bool = false) -> [DatabaseObject] {
        var result: [DatabaseObject] = []
        for kind in category.kinds {
            for object in database.objects(of: kind, includeSystem: includeSystem) {
                if !search.isEmpty, object.name.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                    continue
                }
                let linked = kind == .linkedTable || kind == .linkedODBCTable
                result.append(DatabaseObject(
                    name: object.name, category: category, isLinked: linked, isSystem: object.isSystem,
                    created: object.created, updated: object.updated,
                    linkTarget: linked ? [object.connect, object.foreignName].compactMap { $0 }.joined(separator: " → ") : nil))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Number of objects per category, for the navigation pane headers.
    public func counts(includeSystem: Bool = false) -> [ObjectCategory: Int] {
        Dictionary(uniqueKeysWithValues: ObjectCategory.allCases.map {
            ($0, objects(in: $0, includeSystem: includeSystem).count)
        })
    }

    public func recordset(forTable name: String) throws -> Recordset {
        try Recordset(table: database.table(named: name))
    }
}

/// Random access to a table's rows for a datasheet: rows are located up
/// front and decoded in blocks as they scroll into view.
public final class Recordset {
    public let table: Table
    public let columns: [Column]
    private let locations: [RowPointer]
    private var blocks: [Int: [[Value]]] = [:]
    private var blockOrder: [Int] = []
    private let blockSize = 256
    private let maxBlocks = 64

    public init(table: Table) throws {
        self.table = table
        columns = table.columns
        locations = try table.rowLocations()
    }

    public var count: Int { locations.count }

    /// The row at `index`; a row that fails to decode reads as all nulls so
    /// one bad record does not stop the datasheet.
    public func row(_ index: Int) -> [Value] {
        let block = index / blockSize
        if blocks[block] == nil { load(block) }
        let rows = blocks[block] ?? []
        let offset = index % blockSize
        return offset < rows.count ? rows[offset] : Array(repeating: .null, count: columns.count)
    }

    public func value(row: Int, column: Int) -> Value {
        let values = row < count ? self.row(row) : []
        return column < values.count ? values[column] : .null
    }

    private func load(_ block: Int) {
        let start = block * blockSize
        let end = min(start + blockSize, locations.count)
        guard start < end else { return }
        var rows: [[Value]] = []
        rows.reserveCapacity(end - start)
        for i in start..<end {
            rows.append((try? table.row(at: locations[i])) ?? Array(repeating: .null, count: columns.count))
        }
        blocks[block] = rows
        blockOrder.append(block)
        if blockOrder.count > maxBlocks { blocks[blockOrder.removeFirst()] = nil }
    }
}
