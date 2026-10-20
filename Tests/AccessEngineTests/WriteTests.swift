import Foundation
import XCTest
@testable import AccessEngine

/// Edits made through the engine survive a save and reopen, with every
/// index still consistent with the rows.
final class WriteTests: XCTestCase {
    static let editable = FixtureTests.fixtures.filter { !$0.format.isJet3 }

    func testInsertUpdateDeleteAllTypes() throws {
        for fixture in Self.editable {
            let db = try Database(url: FixtureTests.url(fixture.file))
            let table = try db.table(named: "AllTypes")
            let before = try table.allRows()
            let col = { (name: String) in table.columns.firstIndex { $0.name == name }! }
            let maxID = before.compactMap { row -> Int32? in if case .long(let v) = row[col("ID")] { return v }; return nil }.max() ?? 0

            let longMemo = String(repeating: "Long text crosses pages. ", count: 600)   // ~30 KB of UTF-16
            let ole = (0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
            var values = [Value](repeating: .null, count: table.columns.count)
            values[col("TextField")] = .text("Inserted — café")
            values[col("MemoField")] = .text(longMemo)
            values[col("ByteField")] = .byte(200)
            values[col("IntField")] = .integer(-1234)
            values[col("LongField")] = .long(987_654)
            values[col("SingleField")] = .single(1.5)
            values[col("DoubleField")] = .double(-2.25)
            values[col("CurrencyField")] = .currency(Decimal(string: "1234.5678")!)
            values[col("DateField")] = .dateTime(AccessDate(rawValue: 45000.5))
            values[col("BoolField")] = .boolean(true)
            values[col("GuidField")] = .guid("{6F9619FF-8B86-D011-B42D-00C04FC964FF}")
            values[col("NumericField")] = .decimal(Decimal(string: "-12345.6789")!)
            values[col("BinaryField")] = .binary([1, 2, 3, 4, 5])
            values[col("OleField")] = .binary(ole)
            let (inserted, stored) = try table.insertRow(values)
            XCTAssertEqual(stored[col("ID")], .long(maxID + 1), fixture.file)

            let short = try table.insertRow([.null, .text("Short"), .text("tiny memo")]).location
            let firstLocation = try table.rowLocations()[0]
            var updated = try table.row(at: firstLocation)
            updated[col("TextField")] = .text(String(repeating: "Grown ", count: 16))
            updated[col("MemoField")] = .text(String(repeating: "m", count: 5000))
            try table.updateRow(at: firstLocation, with: updated)
            try table.deleteRow(at: short)
            XCTAssertEqual(table.declaredRowCount, before.count + 1)

            let reopened = try Database(data: db.savedData())
            try Self.saveForJackcess(reopened, name: fixture.file)
            let again = try reopened.table(named: "AllTypes")
            XCTAssertEqual(again.declaredRowCount, before.count + 1, fixture.file)
            let rows = try again.allRows()
            XCTAssertEqual(rows.count, before.count + 1, fixture.file)
            var expected = values
            expected[col("ID")] = .long(maxID + 1)
            XCTAssertEqual(try again.row(at: inserted), expected, fixture.file)
            XCTAssertEqual(try again.row(at: firstLocation), updated, fixture.file)
            XCTAssertEqual(Array(rows.dropFirst().prefix(before.count - 1)), Array(before.dropFirst()), fixture.file)
            try Self.verifyIndexes(reopened, file: fixture.file)
        }
    }

    func testManyEditsRebuildIndexes() throws {
        for fixture in Self.editable {
            let db = try Database(url: FixtureTests.url(fixture.file))
            let table = try db.table(named: "Indexed")
            let col = { (name: String) in table.columns.firstIndex { $0.name == name }! }
            let original = try table.rowLocations().count

            var added: [RowPointer] = []
            for i in 0..<3_000 {
                var values = [Value](repeating: .null, count: table.columns.count)
                values[col("Name")] = .text("Added \(String(i * 7919 % 3001, radix: 36)) row")
                values[col("Amount")] = i % 5 == 0 ? .null : .double(Double(i) * 1.25 - 900)
                values[col("Small")] = .integer(Int16(i % 400 - 200))
                values[col("Tiny")] = .byte(UInt8(i % 256))
                values[col("Price")] = .currency(Decimal(i) / 4)
                values[col("Ratio")] = .single(Float(i) / 3)
                values[col("When")] = .dateTime(AccessDate(rawValue: 40000 + Double(i) / 24))
                values[col("Flag")] = .boolean(i % 3 == 0)
                values[col("Code")] = .guid(Self.guid(i))
                values[col("Dec")] = .decimal(Decimal(i - 1500) / 8)
                values[col("Bin")] = .binary(Array("bin\(i)".utf8))
                added.append(try table.insertRow(values).location)
            }
            for location in added.enumerated().filter({ $0.offset % 6 == 1 }).map(\.element) {
                try table.deleteRow(at: location)
            }
            let existing = try table.rowLocations().prefix(300)
            for (n, location) in existing.enumerated() {
                var row = try table.row(at: location)
                row[col("Name")] = .text("Renamed \(n) " + String(repeating: "x", count: n % 50))
                row[col("Amount")] = .double(Double(n))
                try table.updateRow(at: location, with: row)
            }
            let expectedCount = original + 3_000 - 500
            XCTAssertEqual(try table.rowLocations().count, expectedCount)

            let reopened = try Database(data: db.savedData())
            try Self.saveForJackcess(reopened, name: "indexed-" + fixture.file)
            XCTAssertEqual(try reopened.table(named: "Indexed").allRows().count, expectedCount, fixture.file)
            try Self.verifyIndexes(reopened, file: fixture.file)
        }
    }

    func testSavingTwiceKeepsChanges() throws {
        let db = try Database(url: FixtureTests.url("ace16-2016.accdb"))
        let table = try db.table(named: "ManyRows")
        try table.insertRow([.null, .text("first"), .long(1)])
        _ = try db.savedData()
        try table.insertRow([.null, .text("second"), .long(2)])
        let reopened = try Database(data: db.savedData())
        let rows = try reopened.table(named: "ManyRows").allRows()
        XCTAssertEqual(rows.suffix(2).map { $0[1] }, [.text("first"), .text("second")])
        try Self.verifyIndexes(reopened, file: "twice")
    }

    func testConstraints() throws {
        let db = try Database(url: FixtureTests.url("jet4-2003.mdb"))
        let table = try db.table(named: "AllTypes")
        let text = table.columns.firstIndex { $0.name == "TextField" }!
        var values = [Value](repeating: .null, count: table.columns.count)
        values[text] = .text(String(repeating: "a", count: 101))
        XCTAssertThrowsError(try table.insertRow(values)) { error in
            XCTAssertEqual(error as? WriteError, .valueTooLong(column: "TextField", limit: 100))
        }
        values[text] = .long(5)
        XCTAssertThrowsError(try table.insertRow(values))
        XCTAssertFalse(db.hasUnsavedChanges)

        let index = EditableIndex(name: "PK", index: table.primaryKey!, physical: 0, isUnique: true,
                                  isPrimary: true, entries: [IndexEntry(key: [0x7F, 1], row: RowPointer(page: 9, row: 0))])
        XCTAssertThrowsError(try index.check([0x7F, 1], values: [.long(1)], columns: [table.columns[0]], excluding: nil)) {
            XCTAssertEqual($0 as? WriteError, .duplicateKey(index: "PK"))
        }
        XCTAssertNoThrow(try index.check([0x7F, 1], values: [.long(1)], columns: [table.columns[0]],
                                         excluding: RowPointer(page: 9, row: 0)))
        XCTAssertThrowsError(try index.check([0x00], values: [.null], columns: [table.columns[0]], excluding: nil)) {
            XCTAssertEqual($0 as? WriteError, .requiredValueMissing("ID"))
        }
    }

    static func guid(_ i: Int) -> String {
        func hex(_ v: Int, _ width: Int) -> String {
            let s = String(v, radix: 16, uppercase: true)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return "{" + hex(i * 2_654_435_761 % 0xFFFF_FFFF, 8) + "-0000-4000-8000-" + hex(i, 12) + "}"
    }

    /// Every index holds exactly one correctly encoded entry per live row,
    /// in order.
    static func verifyIndexes(_ db: Database, file: String) throws {
        for name in db.tableNames() {
            let table = try db.table(named: name)
            let live = Set(try table.rowLocations())
            XCTAssertEqual(live.count, table.declaredRowCount, "\(file) \(name) row count")
            for index in table.indexes {
                let entries = try table.entries(of: index)
                XCTAssertEqual(entries.count, live.count, "\(file) \(name)/\(index.name) entry count")
                XCTAssertEqual(Set(entries.map(\.row)), live, "\(file) \(name)/\(index.name) rows")
                for pair in zip(entries, entries.dropFirst()) where !EditableIndex.precedes(pair.0, pair.1) {
                    XCTFail("\(file) \(name)/\(index.name) out of order")
                    break
                }
                for entry in entries {
                    let key = try table.indexKey(index, for: try table.row(at: entry.row))
                    if key != entry.key {
                        XCTFail("\(file) \(name)/\(index.name) key mismatch at \(entry.row)")
                        break
                    }
                }
            }
        }
    }

    /// Set ACCESS_EDIT_OUTPUT to a folder to keep the edited files, for
    /// checking with Jackcess (Tools/FixtureGen/VerifyEdits.java).
    static func saveForJackcess(_ db: Database, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["ACCESS_EDIT_OUTPUT"] else { return }
        try db.save(to: URL(fileURLWithPath: folder).appendingPathComponent("edited-" + name))
    }
}
