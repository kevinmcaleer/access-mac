import AccessCore
import SwiftUI

/// How an open table is shown, as Access's View button switches it.
enum ObjectViewMode: String, CaseIterable, Identifiable {
    case datasheet = "Datasheet View"
    case design = "Design View"
    var id: String { rawValue }
}

/// The main window: ribbon, navigation pane, object tabs and status bar.
struct DatabaseWindow: View {
    let model: DatabaseModel
    let fileURL: URL?

    @State private var search = ""
    @State private var showSystemObjects = false
    @State private var openObjects: [DatabaseObject] = []
    @State private var activeObjectID: DatabaseObject.ID?
    @State private var viewModes: [DatabaseObject.ID: ObjectViewMode] = [:]
    @State private var ribbonTab: RibbonTab = .home
    @State private var showInfo = false
    @State private var status = ""

    private var activeObject: DatabaseObject? {
        openObjects.first { $0.id == activeObjectID }
    }

    private var activeMode: Binding<ObjectViewMode> {
        Binding(
            get: { activeObjectID.flatMap { viewModes[$0] } ?? .datasheet },
            set: { if let id = activeObjectID { viewModes[id] = $0 } })
    }

    var body: some View {
        NavigationSplitView {
            NavigationPane(model: model, search: $search, showSystemObjects: $showSystemObjects, open: open)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            VStack(spacing: 0) {
                RibbonView(tab: $ribbonTab, activeObject: activeObject, viewMode: activeMode,
                           showSystemObjects: $showSystemObjects, showInfo: $showInfo)
                Divider()
                if openObjects.isEmpty {
                    ContentUnavailableView(
                        "No Objects Open", systemImage: "tablecells",
                        description: Text("Double-click a table in the navigation pane to open it."))
                } else {
                    ObjectTabBar(objects: openObjects, active: $activeObjectID, close: close)
                    Divider()
                    if let object = activeObject {
                        ObjectView(model: model, object: object, mode: activeMode.wrappedValue, status: $status)
                            .id(object.id)
                    }
                }
                Divider()
                StatusBar(model: model, text: activeObject == nil ? "Ready" : activeMode.wrappedValue.rawValue,
                          detail: status)
            }
        }
        .navigationTitle(fileURL?.deletingPathExtension().lastPathComponent ?? "Database")
        .navigationSubtitle(model.database.format.displayName)
        .sheet(isPresented: $showInfo) {
            DatabaseInfoView(model: model, fileURL: fileURL)
        }
    }

    private func open(_ object: DatabaseObject) {
        if !openObjects.contains(object) { openObjects.append(object) }
        activeObjectID = object.id
    }

    private func close(_ object: DatabaseObject) {
        guard let index = openObjects.firstIndex(of: object) else { return }
        openObjects.remove(at: index)
        viewModes[object.id] = nil
        if activeObjectID == object.id {
            activeObjectID = openObjects.isEmpty ? nil : openObjects[min(index, openObjects.count - 1)].id
        }
        status = ""
    }
}

/// What a tab shows for one open object.
struct ObjectView: View {
    let model: DatabaseModel
    let object: DatabaseObject
    let mode: ObjectViewMode
    @Binding var status: String

    var body: some View {
        switch object.category {
        case .tables where object.isLinked:
            ContentUnavailableView(
                "Linked Table", systemImage: "link",
                description: Text("\(object.name) is linked to \(object.linkTarget ?? "another database"). Linked tables open in a later release."))
        case .tables:
            TableView(model: model, name: object.name, mode: mode, status: $status)
        default:
            ContentUnavailableView(
                "\(object.category.rawValue) Coming Soon", systemImage: object.category.symbolName,
                description: Text("\(object.name) is stored in this database. Opening \(object.category.rawValue.lowercased()) is planned in a later epic."))
        }
    }
}

/// A table in Datasheet or Design view.
struct TableView: View {
    let model: DatabaseModel
    let name: String
    let mode: ObjectViewMode
    @Binding var status: String

    @State private var recordset: Recordset?
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Can't Open \(name)", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if let recordset {
                switch mode {
                case .datasheet: DatasheetView(recordset: recordset, status: $status)
                case .design: TableDesignView(table: recordset.table)
                }
            } else {
                ProgressView()
            }
        }
        .task(id: name) {
            do {
                recordset = try model.recordset(forTable: name)
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}
