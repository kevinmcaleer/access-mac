import AccessEngine
import Foundation
import XCTest
@testable import AccessCore

final class EditingTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../AccessEngineTests/Fixtures/\(name)").standardized
        return url
    }

    func testParsing() throws {
        let db = try Database(url: fixture("ace16-2016.accdb"))
        let table = try db.table(named: "AllTypes")
        func column(_ name: String) -> Column { table.columns.first { $0.name == name }! }
        XCTAssertEqual(try ValueParser.parse("1,234", for: column("LongField")), .long(1234))
        XCTAssertEqual(try ValueParser.parse("", for: column("LongField")), .null)
        XCTAssertEqual(try ValueParser.parse("($1,234.50)", for: column("CurrencyField")), .currency(Decimal(string: "-1234.5")!))
        XCTAssertEqual(try ValueParser.parse("yes", for: column("BoolField")), .boolean(true))
        XCTAssertEqual(try ValueParser.parse("3/15/2024 2:30 PM", for: column("DateField")),
                       .dateTime(AccessDate(year: 2024, month: 3, day: 15, hour: 14, minute: 30)))
        XCTAssertEqual(try ValueParser.parse("2024-03-15", for: column("DateField")).displayString, "2024-03-15")
        XCTAssertEqual(try ValueParser.parse("6f9619ff-8b86-d011-b42d-00c04fc964ff", for: column("GuidField")),
                       .guid("{6F9619FF-8B86-D011-B42D-00C04FC964FF}"))
        XCTAssertThrowsError(try ValueParser.parse("300", for: column("ByteField")))
        XCTAssertThrowsError(try ValueParser.parse("2023-02-30", for: column("DateField")))
        XCTAssertThrowsError(try ValueParser.parse("1.2.3", for: column("NumericField")))
        XCTAssertEqual(AccessDate(year: 1899, month: 12, day: 30).rawValue, 0)
        XCTAssertEqual(AccessDate(year: 1900, month: 1, day: 1).rawValue, 2)
        XCTAssertEqual(AccessDate(year: 1899, month: 12, day: 29, hour: 6).rawValue, -1.25)
        XCTAssertFalse(ValueParser.isTypeable(column("ID")))
    }

    func testRecordsetEdits() throws {
        let model = try DatabaseModel(url: fixture("jet4-2003.mdb"))
        let recordset = try model.recordset(forTable: "ManyRows")
        XCTAssertNil(recordset.editingRestriction)
        let count = recordset.count
        let first = recordset.location(ofRow: 0)
        let old = try recordset.setValue(.text("Changed"), at: first, column: 1)
        XCTAssertEqual(recordset.value(row: 0, column: 1), .text("Changed"))
        let added = try recordset.append([.null, .text("New one"), .long(7)])
        XCTAssertEqual(recordset.count, count + 1)
        XCTAssertEqual(recordset.value(row: count, column: 1), .text("New one"))
        let removed = try recordset.delete([first, added])
        XCTAssertEqual(recordset.count, count - 1)
        // Restoring keeps the original AutoNumber.
        let restored = try recordset.append(removed[0], keepingAutoNumbers: true)
        XCTAssertEqual(try recordset.table.row(at: restored)[0], removed[0][0])
        XCTAssertNotEqual(old, .text("Changed"))

        let reopened = try DatabaseModel(data: model.database.savedData())
        XCTAssertEqual(try reopened.recordset(forTable: "ManyRows").count, count)
        XCTAssertNotNil(try model.recordset(forTable: "MSysObjects").editingRestriction)
    }
}
