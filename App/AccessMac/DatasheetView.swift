import AccessCore
import AccessEngine
import AppKit
import SwiftUI

/// Datasheet view: the table's rows in a grid, with Access's record
/// navigation bar underneath.
struct DatasheetView: View {
    let recordset: Recordset
    @Binding var status: String
    @State private var selectedRow: Int?
    @State private var scrollRequest: Int?

    var body: some View {
        VStack(spacing: 0) {
            DatasheetGrid(recordset: recordset, selectedRow: $selectedRow, scrollRequest: $scrollRequest)
            Divider()
            RecordNavigator(count: recordset.count, current: selectedRow) { target in
                selectedRow = target
                scrollRequest = target
            }
        }
        .onAppear { status = "\(recordset.count) records" }
    }
}

/// "Record: ◀ 3 of 120 ▶" with first, previous, next and last buttons.
struct RecordNavigator: View {
    let count: Int
    let current: Int?
    let go: (Int) -> Void
    @State private var typed = ""

    var body: some View {
        HStack(spacing: 4) {
            Text("Record:").foregroundStyle(.secondary)
            button("backward.end.fill", "First record", count > 0) { go(0) }
            button("chevron.backward", "Previous record", (current ?? 0) > 0) { go((current ?? 1) - 1) }
            TextField("", text: $typed)
                .frame(width: 60)
                .multilineTextAlignment(.center)
                .onSubmit {
                    if let n = Int(typed), n >= 1, n <= count { go(n - 1) }
                }
            Text("of \(count)").foregroundStyle(.secondary)
            button("chevron.forward", "Next record", (current ?? -1) < count - 1) { go((current ?? -1) + 1) }
            button("forward.end.fill", "Last record", count > 0) { go(count - 1) }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .onChange(of: current, initial: true) { _, value in
            typed = value.map { String($0 + 1) } ?? ""
        }
    }

    private func button(_ symbol: String, _ help: String, _ enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help(help)
    }
}

/// An NSTableView over a recordset. AppKit's table only asks for the rows
/// on screen, so tables of any size scroll smoothly.
struct DatasheetGrid: NSViewRepresentable {
    let recordset: Recordset
    @Binding var selectedRow: Int?
    @Binding var scrollRequest: Int?

    func makeCoordinator() -> Coordinator { Coordinator(recordset: recordset, selectedRow: $selectedRow) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .plain
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 6, height: 2)

        for (index, column) in recordset.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            tableColumn.title = column.name
            tableColumn.headerToolTip = column.type.accessName
            tableColumn.width = Self.width(for: column)
            tableColumn.minWidth = 40
            table.addTableColumn(tableColumn)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        if let target = scrollRequest {
            table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            table.scrollRowToVisible(target)
            DispatchQueue.main.async { scrollRequest = nil }
        }
    }

    static func width(for column: Column) -> CGFloat {
        switch column.type {
        case .boolean: return 60
        case .byte, .integer: return 70
        case .long, .bigInt, .single, .double, .currency, .numeric: return 110
        case .dateTime, .extendedDateTime: return 150
        case .guid: return 290
        case .memo: return 260
        case .text: return CGFloat(min(max(column.size, 10), 40) * 7 + 20)
        default: return 120
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let recordset: Recordset
        var selectedRow: Binding<Int?>

        init(recordset: Recordset, selectedRow: Binding<Int?>) {
            self.recordset = recordset
            self.selectedRow = selectedRow
        }

        func numberOfRows(in tableView: NSTableView) -> Int { recordset.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = Int(tableColumn.identifier.rawValue) else { return nil }
            let column = recordset.columns[index]
            let value = recordset.value(row: row, column: index)

            if column.type == .boolean {
                let id = NSUserInterfaceItemIdentifier("check")
                let check = tableView.makeView(withIdentifier: id, owner: nil) as? NSButton
                    ?? {
                        let b = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                        b.identifier = id
                        b.isEnabled = false
                        return b
                    }()
                check.state = value == .boolean(true) ? .on : .off
                return check
            }

            let id = NSUserInterfaceItemIdentifier("text")
            let field = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField
                ?? {
                    let f = NSTextField(labelWithString: "")
                    f.identifier = id
                    f.lineBreakMode = .byTruncatingTail
                    f.cell?.truncatesLastVisibleLine = true
                    return f
                }()
            let text = value.displayString
            field.stringValue = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            field.toolTip = text.count > 40 ? String(text.prefix(1000)) : nil
            field.alignment = Self.isNumeric(column.type) ? .right : .left
            return field
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            selectedRow.wrappedValue = table.selectedRow >= 0 ? table.selectedRow : nil
        }

        static func isNumeric(_ type: ColumnType) -> Bool {
            switch type {
            case .byte, .integer, .long, .bigInt, .single, .double, .currency, .numeric, .dateTime: return true
            default: return false
            }
        }
    }
}
