import Foundation
import XCTest
@testable import AccessEngine

/// Index B-trees read back in the order Jackcess iterates them, and every
/// stored key equals the key our encoder computes for that row.
final class IndexTests: XCTestCase {
    func testIndexOrderAndKeysMatch() throws {
        for fixture in FixtureTests.fixtures {
            let db = try Database(url: FixtureTests.url(fixture.file))
            let json = try JSONSerialization.jsonObject(
                with: Data(contentsOf: FixtureTests.url(fixture.file + ".json"))) as! [String: Any]
            let expected = json["indexes"] as! [String: [Int]]
            XCTAssertFalse(expected.isEmpty)

            for (path, ids) in expected {
                let parts = path.split(separator: "/").map(String.init)
                let table = try db.table(named: parts[0])
                let index = try XCTUnwrap(table.indexes.first { $0.name == parts[1] }, path)
                let idColumn = try XCTUnwrap(table.columns.firstIndex { $0.name == "ID" })
                let entries = try table.entries(of: index)

                var actualIDs: [Int] = []
                var mismatches = 0
                for entry in entries {
                    let row = try table.row(at: entry.row)
                    guard case .long(let id) = row[idColumn] else { return XCTFail("\(path): no ID") }
                    actualIDs.append(Int(id))
                    let key = try table.indexKey(index, for: row)
                    if key != entry.key {
                        mismatches += 1
                        if mismatches <= 3 {
                            XCTFail("\(fixture.file) \(path) ID \(id): encoded \(hex(key)) but stored \(hex(entry.key))")
                        }
                    }
                }
                XCTAssertEqual(mismatches, 0, "\(fixture.file) \(path) key mismatches")
                XCTAssertEqual(actualIDs, ids, "\(fixture.file) \(path) order")
            }
        }
    }

    func testIndexMetadata() throws {
        let db = try Database(url: FixtureTests.url("ace16-2016.accdb"))
        let table = try db.table(named: "Indexed")
        let byAmount = try XCTUnwrap(table.indexes.first { $0.name == "ByAmountDesc" })
        XCTAssertEqual(byAmount.columns.map(\.ascending), [false])
        let compound = try XCTUnwrap(table.indexes.first { $0.name == "ByNameDescAmount" })
        XCTAssertEqual(compound.columns.map(\.ascending), [false, true])
        XCTAssertEqual(table.columns.first { $0.name == "Name" }?.sortOrder, .general)
        let legacy = try Database(url: FixtureTests.url("jet4-2003.mdb")).table(named: "Indexed")
        XCTAssertEqual(legacy.columns.first { $0.name == "Name" }?.sortOrder, .generalLegacy)
    }

    func testBinaryEntrySegments() {
        XCTAssertEqual(IndexKeyEncoder.binaryEntry([1, 2, 3], ascending: true), [1, 2, 3, 0, 0, 0, 0, 0, 3])
        let nine = IndexKeyEncoder.binaryEntry(Array(1...9), ascending: true)
        XCTAssertEqual(nine, [1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(IndexKeyEncoder.binaryEntry([1], ascending: false), [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE])
    }

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
}
