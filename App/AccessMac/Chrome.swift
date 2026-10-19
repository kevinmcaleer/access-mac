import AccessCore
import SwiftUI

/// The tabs of the Access ribbon.
enum RibbonTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case create = "Create"
    case externalData = "External Data"
    case databaseTools = "Database Tools"
    var id: String { rawValue }
}

/// A compact take on the Access ribbon. Commands that need features from
/// later epics are shown but disabled, so the layout is already familiar.
struct RibbonView: View {
    @Binding var tab: RibbonTab
    let activeObject: DatabaseObject?
    @Binding var viewMode: ObjectViewMode
    @Binding var showSystemObjects: Bool
    @Binding var showInfo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Ribbon", selection: $tab) {
                ForEach(RibbonTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)

            HStack(spacing: 14) {
                switch tab {
                case .home:
                    RibbonGroup("Views") {
                        Picker("View", selection: $viewMode) {
                            ForEach(ObjectViewMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .disabled(activeObject?.category != .tables)
                    }
                    RibbonGroup("Records") {
                        RibbonButton("New", "plus.rectangle", enabled: false)
                        RibbonButton("Save", "square.and.arrow.down", enabled: false)
                        RibbonButton("Delete", "trash", enabled: false)
                    }
                    RibbonGroup("Sort & Filter") {
                        RibbonButton("Ascending", "arrow.up", enabled: false)
                        RibbonButton("Descending", "arrow.down", enabled: false)
                        RibbonButton("Filter", "line.3.horizontal.decrease", enabled: false)
                    }
                case .create:
                    RibbonGroup("Tables") { RibbonButton("Table", "tablecells.badge.ellipsis", enabled: false) }
                    RibbonGroup("Queries") { RibbonButton("Query Design", "square.stack.3d.up", enabled: false) }
                    RibbonGroup("Forms") { RibbonButton("Form", "rectangle.on.rectangle", enabled: false) }
                    RibbonGroup("Reports") { RibbonButton("Report", "doc.richtext", enabled: false) }
                    RibbonGroup("Macros & Code") {
                        RibbonButton("Macro", "bolt", enabled: false)
                        RibbonButton("Module", "chevron.left.forwardslash.chevron.right", enabled: false)
                    }
                case .externalData:
                    RibbonGroup("Import & Link") {
                        RibbonButton("Excel", "tablecells", enabled: false)
                        RibbonButton("Text File", "doc.plaintext", enabled: false)
                    }
                    RibbonGroup("Export") {
                        RibbonButton("Excel", "tablecells", enabled: false)
                        RibbonButton("Text File", "doc.plaintext", enabled: false)
                    }
                case .databaseTools:
                    RibbonGroup("Tools") {
                        RibbonButton("Compact & Repair", "wrench.and.screwdriver", enabled: false)
                    }
                    RibbonGroup("Show") {
                        Toggle("System Objects", isOn: $showSystemObjects)
                            .toggleStyle(.checkbox)
                    }
                    RibbonGroup("Database") {
                        RibbonButton("Info", "info.circle") { showInfo = true }
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) { content }
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct RibbonButton: View {
    let title: String
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    init(_ title: String, _ symbol: String, enabled: Bool = true, action: @escaping () -> Void = {}) {
        self.title = title
        self.symbol = symbol
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.caption)
            }
            .frame(minWidth: 52)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(enabled ? title : "\(title) is not available yet")
    }
}

/// Tabs for the open objects, like Access's tabbed documents.
struct ObjectTabBar: View {
    let objects: [DatabaseObject]
    @Binding var active: DatabaseObject.ID?
    let close: (DatabaseObject) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(objects) { object in
                    let isActive = object.id == active
                    HStack(spacing: 6) {
                        Image(systemName: object.category.symbolName).font(.caption)
                        Text(object.name).lineLimit(1)
                        Button { close(object) } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.borderless)
                            .help("Close \(object.name)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                    .overlay(alignment: .bottom) {
                        if isActive { Rectangle().fill(Color.accentColor).frame(height: 2) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { active = object.id }
                    Divider()
                }
            }
        }
        .frame(height: 28)
        .background(.bar)
    }
}

struct StatusBar: View {
    let model: DatabaseModel
    let text: String
    let detail: String

    var body: some View {
        HStack {
            Text(text)
            Spacer()
            if !detail.isEmpty { Text(detail).foregroundStyle(.secondary) }
            Text("Read-only").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

/// The Info screen of Access's File tab.
struct DatabaseInfoView: View {
    let model: DatabaseModel
    let fileURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let db = model.database
        let counts = model.counts()
        VStack(alignment: .leading, spacing: 16) {
            Text("Info").font(.largeTitle.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("File", fileURL?.path ?? "Unsaved")
                row("Format", db.format.displayName)
                if let size = model.fileSize {
                    row("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
                row("Pages", "\(db.pageCount) × \(db.pageSize / 1024) KB")
                row("Code page", "\(db.codePage)")
                row("Encoded", db.isEncoded ? "Yes" : "No")
                ForEach(ObjectCategory.allCases) { category in
                    row(category.rawValue, "\(counts[category] ?? 0)")
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
