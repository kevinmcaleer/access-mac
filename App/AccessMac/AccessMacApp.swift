import SwiftUI

@main
struct AccessMacApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { AccessDocument() }) { file in
            DatabaseWindow(model: file.document.model, fileURL: file.fileURL)
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
