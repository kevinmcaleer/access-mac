import AccessCore
import AccessEngine
import AppKit
import SwiftUI

extension Notification.Name {
    /// Ribbon commands for the active datasheet.
    static let datasheetNewRecord = Notification.Name("AccessMac.datasheetNewRecord")
    static let datasheetDeleteRecords = Notification.Name("AccessMac.datasheetDeleteRecords")
    /// Posted with the `Table` whose records changed, so every datasheet on
    /// it reloads (including after undo).
    static let tableRecordsDidChange = Notification.Name("AccessMac.tableRecordsDidChange")
}

/// Datasheet view: the table's rows in a grid, with Access's record
/// navigation bar underneath. Cells edit in place; the last row adds a
/// record.
struct DatasheetView: View {
    let recordset: Recordset
    @Binding var status: String
    @Environment(\.undoManager) private var undoManager
    @State private var selectedRow: Int?
    @State private var scrollRequest: Int?
    @State private var count = 0

    var body: some View {
        VStack(spacing: 0) {
            DatasheetGrid(recordset: recordset, undoManager: undoManager, selectedRow: $selectedRow,
                          scrollRequest: $scrollRequest, count: $count)
            Divider()
            RecordNavigator(count: count, current: selectedRow) { target in
                selectedRow = target
                scrollRequest = target
            }
        }
        .onAppear { count = recordset.count }
        .onChange(of: count, initial: true) { _, value in
            if let restriction = recordset.editingRestriction {
                status = "\(value) records · Read-only: \(restriction)"
            } else {
                status = "\(value) records"
            }
        }
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

/// Record changes that register their own undo, so the document is marked
/// edited and Edit > Undo reverses them.
enum RecordEdits {
    static func change(_ value: Value, at location: RowPointer, column: Int, in recordset: Recordset,
                    undoManager: UndoManager?) throws {
        let old = try recordset.setValue(value, at: location, column: column)
        undoManager?.registerUndo(withTarget: recordset) { recordset in
            perform { try change(old, at: location, column: column, in: recordset, undoManager: undoManager) }
        }
        undoManager?.setActionName("Edit \(recordset.columns[column].name)")
        changed(recordset)
    }

    @discardableResult
    static func append(_ values: [Value], keepingAutoNumbers: Bool = false, to recordset: Recordset,
                       undoManager: UndoManager?) throws -> RowPointer {
        let location = try recordset.append(values, keepingAutoNumbers: keepingAutoNumbers)
        undoManager?.registerUndo(withTarget: recordset) { recordset in
            perform { try delete([location], from: recordset, undoManager: undoManager) }
        }
        undoManager?.setActionName("New Record")
        changed(recordset)
        return location
    }

    static func delete(_ locations: [RowPointer], from recordset: Recordset, undoManager: UndoManager?) throws {
        let removed = try recordset.delete(locations)
        undoManager?.registerUndo(withTarget: recordset) { recordset in
            perform {
                for values in removed {
                    try append(values, keepingAutoNumbers: true, to: recordset, undoManager: undoManager)
                }
            }
        }
        undoManager?.setActionName(locations.count == 1 ? "Delete Record" : "Delete Records")
        changed(recordset)
    }

    private static func changed(_ recordset: Recordset) {
        NotificationCenter.default.post(name: .tableRecordsDidChange, object: recordset.table)
    }

    static func perform(_ body: () throws -> Void) {
        do { try body() } catch { present(error) }
    }

    static func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The change couldn't be saved."
        alert.informativeText = String(describing: error)
        alert.runModal()
    }
}

/// A cell that switches to the value's editing text when editing starts.
final class DatasheetTextField: NSTextField {
    var editingText: String?

    override func becomeFirstResponder() -> Bool {
        if isEditable, let editingText { stringValue = editingText }
        return super.becomeFirstResponder()
    }
}

/// A table view that sends Delete to its coordinator.
final class DatasheetTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
           key == 0x7F || key == UInt32(NSDeleteFunctionKey) {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// An NSTableView over a recordset. AppKit's table only asks for the rows
/// on screen, so tables of any size scroll smoothly.
struct DatasheetGrid: NSViewRepresentable {
    let recordset: Recordset
    let undoManager: UndoManager?
    @Binding var selectedRow: Int?
    @Binding var scrollRequest: Int?
    @Binding var count: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(recordset: recordset, selectedRow: $selectedRow, count: $count)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DatasheetTableView()
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
        table.onDelete = { [weak coordinator = context.coordinator] in coordinator?.deleteSelected() }
        context.coordinator.tableView = table
        context.coordinator.undoManager = undoManager

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.undoManager = undoManager
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

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        let recordset: Recordset
        let isEditable: Bool
        var selectedRow: Binding<Int?>
        var count: Binding<Int>
        weak var tableView: NSTableView?
        var undoManager: UndoManager?
        private var observers: [NSObjectProtocol] = []

        init(recordset: Recordset, selectedRow: Binding<Int?>, count: Binding<Int>) {
            self.recordset = recordset
            self.selectedRow = selectedRow
            self.count = count
            isEditable = recordset.editingRestriction == nil
            super.init()
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .tableRecordsDidChange, object: recordset.table, queue: .main) {
                [weak self] _ in self?.reload()
            })
            observers.append(center.addObserver(forName: .datasheetNewRecord, object: nil, queue: .main) {
                [weak self] _ in self?.beginNewRecord()
            })
            observers.append(center.addObserver(forName: .datasheetDeleteRecords, object: nil, queue: .main) {
                [weak self] _ in self?.deleteSelected()
            })
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        private var newRow: Int { recordset.count }

        func numberOfRows(in tableView: NSTableView) -> Int { recordset.count + (isEditable ? 1 : 0) }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = Int(tableColumn.identifier.rawValue) else { return nil }
            let column = recordset.columns[index]
            let isNewRow = row == newRow
            let value = isNewRow ? Value.null : recordset.value(row: row, column: index)

            if column.type == .boolean {
                let id = NSUserInterfaceItemIdentifier("check")
                let check = tableView.makeView(withIdentifier: id, owner: nil) as? NSButton
                    ?? {
                        let b = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                        b.identifier = id
                        return b
                    }()
                check.target = self
                check.action = #selector(toggle(_:))
                check.isEnabled = isEditable
                check.state = value == .boolean(true) ? .on : .off
                return check
            }

            let id = NSUserInterfaceItemIdentifier("text")
            let field = tableView.makeView(withIdentifier: id, owner: nil) as? DatasheetTextField
                ?? {
                    let f = DatasheetTextField(string: "")
                    f.identifier = id
                    f.isBordered = false
                    f.drawsBackground = false
                    f.lineBreakMode = .byTruncatingTail
                    f.cell?.truncatesLastVisibleLine = true
                    f.cell?.isScrollable = true
                    return f
                }()
            field.delegate = self
            field.isEditable = isEditable && ValueParser.isTypeable(column)
            // Editing shows the full value: memo line breaks, currency
            // without rounding.
            field.editingText = isNewRow ? nil : ValueParser.editingText(value)
            if isNewRow {
                field.stringValue = ""
                field.placeholderString = column.isAutoNumber ? "(New)" : nil
            } else {
                field.placeholderString = nil
                let text = value.displayString
                field.stringValue = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                field.toolTip = text.count > 40 ? String(text.prefix(1000)) : nil
            }
            field.alignment = Self.isNumeric(column.type) ? .right : .left
            return field
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            let row = table.selectedRow
            selectedRow.wrappedValue = row >= 0 && row < recordset.count ? row : nil
        }

        // MARK: Editing

        private func position(of view: NSView) -> (row: Int, column: Int)? {
            guard let table = tableView else { return nil }
            let row = table.row(for: view), columnIndex = table.column(for: view)
            guard row >= 0, columnIndex >= 0,
                  let column = Int(table.tableColumns[columnIndex].identifier.rawValue) else { return nil }
            return (row, column)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let cell = position(of: field) else { return }
            commit(field.stringValue, row: cell.row, column: cell.column)
        }

        private func commit(_ text: String, row: Int, column: Int) {
            let target = recordset.columns[column]
            do {
                if row < recordset.count {
                    let old = recordset.value(row: row, column: column)
                    guard text != ValueParser.editingText(old) else { return reload(row: row) }
                    let value = try ValueParser.parse(text, for: target)
                    guard value != old else { return reload(row: row) }
                    try RecordEdits.change(value, at: recordset.location(ofRow: row), column: column,
                                        in: recordset, undoManager: undoManager)
                } else {
                    guard !text.isEmpty else { return }
                    var values = [Value](repeating: .null, count: recordset.columns.count)
                    values[column] = try ValueParser.parse(text, for: target)
                    try RecordEdits.append(values, to: recordset, undoManager: undoManager)
                }
            } catch {
                RecordEdits.present(error)
                reload()
            }
        }

        @objc func toggle(_ sender: NSButton) {
            guard let cell = position(of: sender) else { return }
            let (row, column) = cell
            let value = Value.boolean(sender.state == .on)
            do {
                if row < recordset.count {
                    try RecordEdits.change(value, at: recordset.location(ofRow: row), column: column,
                                        in: recordset, undoManager: undoManager)
                } else {
                    var values = [Value](repeating: .null, count: recordset.columns.count)
                    values[column] = value
                    try RecordEdits.append(values, to: recordset, undoManager: undoManager)
                }
            } catch {
                RecordEdits.present(error)
                reload()
            }
        }

        func beginNewRecord() {
            guard isEditable, let table = tableView, table.window?.isKeyWindow ?? false else { return }
            let row = newRow
            table.scrollRowToVisible(row)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if let first = recordset.columns.firstIndex(where: { ValueParser.isTypeable($0) && $0.type != .boolean }),
               let columnIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "\(first)" }) {
                table.editColumn(columnIndex, row: row, with: nil, select: true)
            }
        }

        func deleteSelected() {
            guard isEditable, let table = tableView, table.window?.isKeyWindow ?? false else { return }
            let rows = table.selectedRowIndexes.filter { $0 < recordset.count }
            guard !rows.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = rows.count == 1 ? "Delete this record?" : "Delete \(rows.count) records?"
            alert.informativeText = "You can undo this with Edit > Undo until you close the database."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            RecordEdits.perform {
                try RecordEdits.delete(rows.map(recordset.location(ofRow:)), from: recordset, undoManager: undoManager)
            }
            reload()
        }

        private func reload(row: Int? = nil) {
            guard let table = tableView else { return }
            if let row {
                table.reloadData(forRowIndexes: IndexSet(integer: row),
                                 columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                return
            }
            try? recordset.refresh()
            table.reloadData()
            count.wrappedValue = recordset.count
        }

        static func isNumeric(_ type: ColumnType) -> Bool {
            switch type {
            case .byte, .integer, .long, .bigInt, .single, .double, .currency, .numeric, .dateTime: return true
            default: return false
            }
        }
    }
}
