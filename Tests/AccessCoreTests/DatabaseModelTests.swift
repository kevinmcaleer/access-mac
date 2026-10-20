import AccessEngine
import Foundation
import XCTest
@testable import AccessCore

final class DatabaseModelTests: XCTestCase {
    /// The engine's fixtures, reached from this package's source tree.
    func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AccessEngineTests/Fixtures/\(name)")
    }

    func testNavigationPaneObjects() throws {
        let model = try DatabaseModel(url: fixture("ace16-2016.accdb"))
        XCTAssertEqual(model.objects(in: .tables).map(\.name),
                       ["AllTypes", "BigNumbers", "Customers & Orders", "Indexed", "ManyRows"])
        XCTAssertEqual(model.objects(in: .tables, search: "rows").map(\.name), ["ManyRows"])
        XCTAssertTrue(model.objects(in: .tables, includeSystem: true).contains { $0.name == "MSysObjects" })
        XCTAssertEqual(model.objects(in: .forms), [])
        XCTAssertEqual(model.counts()[.tables], 5)
        XCTAssertNotNil(model.fileSize)
    }

    func testRecordsetPaging() throws {
        let model = try DatabaseModel(url: fixture("jet4-2003.mdb"))
        let rs = try model.recordset(forTable: "ManyRows")
        XCTAssertEqual(rs.count, 1286)
        XCTAssertEqual(rs.columns.map(\.name), ["ID", "Name", "Value"])
        XCTAssertEqual(rs.value(row: 0, column: 1), .text("Row number 1"))
        // Row 1000 sits in a later block. IDs divisible by 7 were deleted, so
        // the 1001st surviving row has ID 1001 + 1000 / 6.
        XCTAssertEqual(rs.value(row: 1000, column: 0), .long(1167))
        XCTAssertEqual(rs.value(row: 1000, column: 2), .long(1167 * 3))
        XCTAssertEqual(rs.value(row: 99_999, column: 0), .null)
    }
}
