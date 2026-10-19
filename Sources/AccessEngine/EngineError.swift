/// Errors raised while opening or reading a database file.
public enum EngineError: Error, Equatable, CustomStringConvertible {
    case notAnAccessDatabase
    case unsupportedVersion(UInt8)
    case encryptedDatabase(String)
    case pageOutOfRange(UInt32)
    case corruptPage(UInt32, String)
    case tableNotFound(String)
    case corruptRow(String)

    public var description: String {
        switch self {
        case .notAnAccessDatabase: return "The file is not a Microsoft Access database."
        case .unsupportedVersion(let v): return "Unsupported database version (0x\(String(v, radix: 16)))."
        case .encryptedDatabase(let kind): return "The database is encrypted (\(kind)); encrypted databases are not supported yet."
        case .pageOutOfRange(let p): return "Page \(p) is beyond the end of the file."
        case .corruptPage(let p, let why): return "Page \(p) is corrupt: \(why)."
        case .tableNotFound(let name): return "No table named \"\(name)\"."
        case .corruptRow(let why): return "Corrupt row: \(why)."
        }
    }
}
