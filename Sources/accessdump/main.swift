import AccessEngine
import Foundation

// accessdump <file> [table]
//   With only a file: prints the format and lists every object.
//   With a table name: prints the table's rows as tab-separated text.

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: accessdump <database> [table] [--system]\n".data(using: .utf8)!)
    exit(64)
}
do {
    let db = try Database(url: URL(fileURLWithPath: args[1]))
    let includeSystem = args.contains("--system")
    let positional = args.dropFirst(2).filter { !$0.hasPrefix("--") }
    if let name = positional.first {
        let table = try db.table(named: name)
        print(table.columns.map(\.name).joined(separator: "\t"))
        for location in try table.rowLocations() {
            let row = try table.row(at: location)
            print(row.map { $0.displayString.replacingOccurrences(of: "\n", with: "\\n") }.joined(separator: "\t"))
        }
    } else {
        print("Format: \(db.format.displayName), page size \(db.pageSize), \(db.pageCount) pages, code page \(db.codePage)")
        for object in db.catalog.sorted(by: { $0.name < $1.name }) where includeSystem || !object.isSystem {
            print("\(object.kind)\t\(object.name)")
        }
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
