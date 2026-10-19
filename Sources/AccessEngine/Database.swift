import Foundation

/// An entry in MSysObjects, the system catalog.
public struct CatalogObject: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case table, linkedTable, linkedODBCTable, query, form, report, macro, module
        case relationship, databaseProperties, container, other(Int16)
    }

    public let id: Int32
    public let parentId: Int32
    public let name: String
    public let kind: Kind
    public let flags: Int32
    public let created: AccessDate?
    public let updated: AccessDate?
    /// The source table name of a linked table.
    public let foreignName: String?
    /// The connection string of a linked table.
    public let connect: String?

    /// MSys* tables and objects Access flags as system or hidden.
    public var isSystem: Bool {
        name.hasPrefix("MSys") || name.hasPrefix("f_") && kind == .table
            || flags & Int32(bitPattern: 0x8000_0000) != 0 || flags & 0x2 != 0
    }

    /// The page holding a table's definition.
    var tableDefinitionPage: UInt32 { UInt32(bitPattern: id) & 0x00FF_FFFF }

    static func kind(for type: Int16) -> Kind {
        switch type {
        case 1: return .table
        case 2: return .databaseProperties
        case 3: return .container
        case 4: return .linkedODBCTable
        case 5: return .query
        case 6: return .linkedTable
        case 8: return .relationship
        case -32768: return .form
        case -32764: return .report
        case -32766: return .macro
        case -32761: return .module
        default: return .other(type)
        }
    }
}

/// An open Access database (.mdb or .accdb), read from disk.
public final class Database {
    public let url: URL?
    let source: PageSource
    let codec: TextCodec
    public private(set) var catalog: [CatalogObject] = []
    private var tableCache: [String: Table] = [:]

    public var format: FileFormat { source.header.format }
    public var codePage: UInt16 { source.header.codePage }
    public var pageSize: Int { source.layout.pageSize }
    public var pageCount: Int { Int(source.pageCount) }
    /// True when the pages of a Jet 3/4 database are RC4-encoded.
    public var isEncoded: Bool { source.header.databaseKey != 0 }

    public convenience init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try self.init(data: data, url: url)
    }

    public init(data: Data, url: URL? = nil) throws {
        self.url = url
        source = try PageSource(data: data)
        codec = TextCodec(format: source.header.format, codePage: source.header.codePage)
        try loadCatalog()
    }

    /// MSysObjects always starts on page 2.
    private func loadCatalog() throws {
        let definition = try TableDefinition(page: 2, source: source)
        let system = Table(name: "MSysObjects", definition: definition, database: self)
        let columns = definition.columns
        func index(_ name: String) -> Int? { columns.firstIndex { $0.name == name } }
        let id = index("Id"), parent = index("ParentId"), name = index("Name"), type = index("Type")
        let flags = index("Flags"), created = index("DateCreate"), updated = index("DateUpdate")
        let foreign = index("ForeignName"), connect = index("Connect")
        guard let id, let name, let type else {
            throw EngineError.corruptPage(2, "MSysObjects is missing Id, Name or Type")
        }
        var objects: [CatalogObject] = []
        for location in try system.rowLocations() {
            let row = try system.row(at: location)
            guard case .text(let objectName) = row[name] else { continue }
            func int32(_ i: Int?) -> Int32 {
                guard let i else { return 0 }
                switch row[i] {
                case .long(let v): return v
                case .integer(let v): return Int32(v)
                default: return 0
                }
            }
            func date(_ i: Int?) -> AccessDate? {
                guard let i, case .dateTime(let d) = row[i] else { return nil }
                return d
            }
            func text(_ i: Int?) -> String? {
                guard let i, case .text(let s) = row[i] else { return nil }
                return s
            }
            let typeCode: Int16
            if case .integer(let t) = row[type] { typeCode = t } else { typeCode = 0 }
            objects.append(CatalogObject(
                id: int32(id), parentId: int32(parent), name: objectName,
                kind: CatalogObject.kind(for: typeCode), flags: int32(flags),
                created: date(created), updated: date(updated),
                foreignName: text(foreign), connect: text(connect)))
        }
        catalog = objects
        tableCache["MSysObjects"] = system
    }

    /// Objects of one kind, sorted by name, optionally including system ones.
    public func objects(of kind: CatalogObject.Kind, includeSystem: Bool = false) -> [CatalogObject] {
        catalog.filter { $0.kind == kind && (includeSystem || !$0.isSystem) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Names of the local tables, sorted.
    public func tableNames(includeSystem: Bool = false) -> [String] {
        objects(of: .table, includeSystem: includeSystem).map(\.name)
    }

    public func table(named name: String) throws -> Table {
        if let cached = tableCache[name] { return cached }
        guard let object = catalog.first(where: {
            $0.kind == .table && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw EngineError.tableNotFound(name)
        }
        let definition = try TableDefinition(page: object.tableDefinitionPage, source: source)
        let table = Table(name: object.name, definition: definition, database: self)
        tableCache[name] = table
        return table
    }
}
