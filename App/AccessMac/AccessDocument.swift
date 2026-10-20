import AccessCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let accessMDB = UTType(importedAs: "com.microsoft.access.mdb")
    static let accessACCDB = UTType(importedAs: "com.microsoft.access.accdb")
}

/// A .mdb or .accdb file opened in a window.
struct AccessDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.accessACCDB, .accessMDB] }
    static var writableContentTypes: [UTType] { [] }

    let model: DatabaseModel

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        model = try DatabaseModel(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}
