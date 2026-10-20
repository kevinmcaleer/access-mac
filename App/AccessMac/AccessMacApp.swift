import SwiftUI

@main
struct AccessMacApp: App {
    var body: some Scene {
        // Read-only until the engine's write path lands (Epic 2, #20).
        DocumentGroup(viewing: AccessDocument.self) { file in
            DatabaseWindow(model: file.document.model, fileURL: file.fileURL)
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
