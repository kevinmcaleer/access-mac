import AccessCore
import SwiftUI

/// The navigation pane: every object, grouped by type, with a search box.
struct NavigationPane: View {
    let model: DatabaseModel
    @Binding var search: String
    @Binding var showSystemObjects: Bool
    let open: (DatabaseObject) -> Void

    @State private var selection: DatabaseObject.ID?
    @State private var expanded: Set<ObjectCategory> = Set(ObjectCategory.allCases)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .padding(8)

            List(selection: $selection) {
                ForEach(ObjectCategory.allCases) { category in
                    let objects = model.objects(in: category, search: search, includeSystem: showSystemObjects)
                    if !objects.isEmpty {
                        Section(isExpanded: binding(for: category)) {
                            ForEach(objects) { object in
                                Label {
                                    Text(object.name)
                                        .foregroundStyle(object.isSystem ? .secondary : .primary)
                                } icon: {
                                    Image(systemName: object.isLinked ? "link" : category.symbolName)
                                }
                                .tag(object.id)
                                .help(object.linkTarget ?? object.name)
                            }
                        } header: {
                            Text("\(category.rawValue) (\(objects.count))")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: DatabaseObject.ID.self) { ids in
                Button("Open") { ids.compactMap(object(for:)).forEach(open) }
            } primaryAction: { ids in
                ids.compactMap(object(for:)).forEach(open)
            }
        }
    }

    private func object(for id: DatabaseObject.ID) -> DatabaseObject? {
        for category in ObjectCategory.allCases {
            if let match = model.objects(in: category, includeSystem: true).first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    private func binding(for category: ObjectCategory) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(category) },
            set: { if $0 { expanded.insert(category) } else { expanded.remove(category) } })
    }
}
