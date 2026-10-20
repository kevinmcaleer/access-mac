import AccessCore
import AccessEngine
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let accessMDB = UTType(importedAs: "com.microsoft.access.mdb")
    static let accessACCDB = UTType(importedAs: "com.microsoft.access.accdb")
}

/// A .mdb or .accdb file opened in a window. Edits change the database in
/// memory and register undo actions, which marks the document as edited;
/// saving writes the whole file.
final class AccessDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.accessACCDB, .accessMDB] }
    static var writableContentTypes: [UTType] { [.accessACCDB, .accessMDB] }

    let model: DatabaseModel

    /// A new, empty database, from a blank Access 2016 template.
    init() {
        guard let url = Bundle.main.url(forResource: "Blank", withExtension: "accdb"),
              let model = try? DatabaseModel(url: url) else {
            fatalError("The blank database template is missing from the app.")
        }
        self.model = model
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        model = try DatabaseModel(data: data)
    }

    func snapshot(contentType: UTType) throws -> Data {
        let format = model.database.format
        // The engine saves in the file's own format; converting is separate.
        let wantsACCDB = contentType.conforms(to: .accessACCDB)
        if wantsACCDB != format.isACE {
            throw CocoaError(.fileWriteUnsupportedScheme, userInfo: [
                NSLocalizedDescriptionKey: "This database is in \(format.displayName) format. Save it with the .\(format.isACE ? "accdb" : "mdb") extension.",
            ])
        }
        return try model.database.savedData()
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
