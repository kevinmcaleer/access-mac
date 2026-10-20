import AccessEngine
import SwiftUI

/// Design view, read-only for now: each field's name, type and size, and
/// the table's indexes.
struct TableDesignView: View {
    let table: AccessEngine.Table

    struct FieldRow: Identifiable {
        let id: Int
        let name: String
        let type: String
        let size: String
        let notes: String
        let isKey: Bool
    }

    private var rows: [FieldRow] {
        let keyColumns = Set(table.primaryKey?.columns.map(\.number) ?? [])
        return table.columns.map { column in
            var notes: [String] = []
            if column.isAutoNumber { notes.append("AutoNumber") }
            if column.isHyperlink { notes.append("Hyperlink") }
            if column.isCalculated { notes.append("Calculated") }
            if column.type == .numeric { notes.append("Precision \(column.precision), scale \(column.scale)") }
            let size: String
            switch column.type {
            case .text, .binary: size = "\(column.size)"
            default: size = ""
            }
            return FieldRow(id: column.number, name: column.name, type: column.type.accessName,
                            size: size, notes: notes.joined(separator: ", "),
                            isKey: keyColumns.contains(column.number))
        }
    }

    var body: some View {
        VSplitView {
            SwiftUI.Table(rows) {
                SwiftUI.TableColumn("") { row in
                    if row.isKey { Image(systemName: "key.fill").foregroundStyle(.yellow) }
                }
                .width(24)
                SwiftUI.TableColumn("Field Name", value: \.name)
                SwiftUI.TableColumn("Data Type", value: \.type)
                SwiftUI.TableColumn("Field Size", value: \.size).width(80)
                SwiftUI.TableColumn("Description", value: \.notes)
            }
            .frame(minHeight: 200)

            VStack(alignment: .leading, spacing: 6) {
                Text("Indexes").font(.headline)
                if table.indexes.isEmpty {
                    Text("No indexes").foregroundStyle(.secondary)
                }
                ForEach(table.indexes, id: \.name) { index in
                    HStack {
                        Image(systemName: index.kind == .primaryKey ? "key.fill" : "list.number")
                        Text(index.name).bold()
                        Text(indexColumns(index)).foregroundStyle(.secondary)
                        if index.isUnique { Text("Unique").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        }
    }

    private func indexColumns(_ index: AccessEngine.Index) -> String {
        index.columns.map { key in
            let name = table.columns.first { $0.number == key.number }?.name ?? "#\(key.number)"
            return key.ascending ? name : "\(name) (desc)"
        }.joined(separator: ", ")
    }
}
