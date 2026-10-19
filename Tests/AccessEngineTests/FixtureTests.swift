import Foundation
import XCTest
@testable import AccessEngine

/// Compares what the engine reads from each fixture with what Jackcess read
/// back when it generated the fixture (the `.json` file beside it).
final class FixtureTests: XCTestCase {
    static let fixtures: [(file: String, format: FileFormat)] = [
        ("jet4-2000.mdb", .jet4),
        ("jet4-2003.mdb", .jet4),
        ("ace12-2007.accdb", .ace12),
        ("ace14-2010.accdb", .ace14),
        ("ace16-2016.accdb", .ace16),
    ]

    static func url(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    func testFormatDetection() throws {
        for fixture in Self.fixtures {
            let db = try Database(url: Self.url(fixture.file))
            XCTAssertEqual(db.format, fixture.format, fixture.file)
            XCTAssertEqual(db.pageSize, 4096)
            XCTAssertFalse(db.isEncoded)
        }
    }

    func testEveryFixtureMatchesJackcess() throws {
        for fixture in Self.fixtures {
            let db = try Database(url: Self.url(fixture.file))
            let json = try JSONSerialization.jsonObject(
                with: Data(contentsOf: Self.url(fixture.file + ".json"))) as! [String: Any]
            let tables = json["tables"] as! [String: [String: Any]]
            XCTAssertEqual(Set(db.tableNames()), Set(tables.keys), fixture.file)

            for (name, expected) in tables {
                let table = try db.table(named: name)
                let columns = expected["columns"] as! [[String: String]]
                XCTAssertEqual(table.columns.map(\.name), columns.map { $0["name"]! }, "\(fixture.file) \(name)")
                let rows = expected["rows"] as! [[Any]]
                let actual = try table.allRows()
                XCTAssertEqual(actual.count, rows.count, "\(fixture.file) \(name) row count")
                for (r, (got, want)) in zip(actual, rows).enumerated() {
                    for (c, (value, raw)) in zip(got, want).enumerated() {
                        let context = "\(fixture.file) \(name) row \(r) \(columns[c]["name"]!)"
                        assertMatches(value, raw, type: columns[c]["type"]!, context)
                    }
                }
            }
        }
    }

    private func assertMatches(_ value: Value, _ raw: Any, type: String, _ context: String) {
        if raw is NSNull {
            XCTAssertEqual(value, .null, context)
            return
        }
        switch (value, raw) {
        case (.boolean(let b), let n as NSNumber): XCTAssertEqual(b, n.boolValue, context)
        // Java bytes are signed; Access bytes are 0-255.
        case (.byte(let v), let n as NSNumber): XCTAssertEqual(v, UInt8(truncatingIfNeeded: n.intValue), context)
        case (.integer(let v), let n as NSNumber): XCTAssertEqual(Int(v), n.intValue, context)
        case (.long(let v), let n as NSNumber): XCTAssertEqual(Int(v), n.intValue, context)
        case (.bigInt(let v), let n as NSNumber): XCTAssertEqual(v, n.int64Value, context)
        case (.single(let v), let n as NSNumber): XCTAssertEqual(v, n.floatValue, context)
        case (.double(let v), let n as NSNumber): XCTAssertEqual(v, n.doubleValue, context)
        case (.currency(let v), let s as String), (.decimal(let v), let s as String):
            XCTAssertEqual(v, Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")), context)
        case (.dateTime(let d), let s as String):
            let c = d.components
            let text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year, c.month, c.day, c.hour, c.minute, c.second)
            let want = s.count == 16 ? s + ":00" : s
            XCTAssertEqual(text, want, context)
        case (.text(let t), let s as String): XCTAssertEqual(t, s, context)
        case (.guid(let g), let s as String): XCTAssertEqual(g, s, context)
        case (.binary(let b), let s as String):
            XCTAssertEqual("hex:" + b.map { String(format: "%02x", $0) }.joined(), s, context)
        default:
            XCTFail("\(context): \(value) does not match \(raw) (\(type))")
        }
    }

    func testCatalogAndMetadata() throws {
        let db = try Database(url: Self.url("ace14-2010.accdb"))
        XCTAssertTrue(db.tableNames(includeSystem: true).contains("MSysObjects"))
        XCTAssertFalse(db.tableNames().contains("MSysObjects"))

        let all = try db.table(named: "AllTypes")
        XCTAssertEqual(all.primaryKey?.columns.map(\.number), [0])
        let id = all.columns[0]
        XCTAssertTrue(id.isAutoNumber)
        XCTAssertEqual(all.columns[1].type, .text)
        XCTAssertEqual(all.columns[1].size, 100)
        let numeric = try XCTUnwrap(all.columns.first { $0.name == "NumericField" })
        XCTAssertEqual(numeric.precision, 18)
        XCTAssertEqual(numeric.scale, 4)

        let many = try db.table(named: "manyrows")
        XCTAssertEqual(try many.rowLocations().count, 1500 - 1500 / 7)
        XCTAssertEqual(many.declaredRowCount, 1500 - 1500 / 7)
    }

    func testRejectsNonAccessFiles() {
        XCTAssertThrowsError(try Database(data: Data(repeating: 0, count: 8192))) { error in
            XCTAssertEqual(error as? EngineError, .notAnAccessDatabase)
        }
        XCTAssertThrowsError(try Database(data: Data("hello".utf8)))
    }

    func testMissingTable() throws {
        let db = try Database(url: Self.url("jet4-2000.mdb"))
        XCTAssertThrowsError(try db.table(named: "Nope")) { error in
            XCTAssertEqual(error as? EngineError, .tableNotFound("Nope"))
        }
    }
}

final class ValueTests: XCTestCase {
    func testAccessDateComponents() {
        XCTAssertEqual(AccessDate(rawValue: 0).description, "1899-12-30")
        XCTAssertEqual(AccessDate(rawValue: 1.5).description, "1899-12-31 12:00:00")
        // Before the epoch the fraction still counts forward from midnight.
        XCTAssertEqual(AccessDate(rawValue: -1.25).description, "1899-12-29 06:00:00")
        XCTAssertEqual(AccessDate(rawValue: 45351).description, "2024-02-29")
    }

    func testJet4CompressedText() {
        // "ab" compressed, then a toggle to UTF-16 for "✓", then back.
        let bytes: [UInt8] = [0xFF, 0xFE, 0x61, 0x62, 0x00, 0x13, 0x27, 0x00, 0x63]
        XCTAssertEqual(TextCodec.decodeJet4(bytes), "ab✓c")
        XCTAssertEqual(TextCodec.decodeJet4([0x68, 0x00, 0x69, 0x00]), "hi")
    }

    func testNumericDecoding() {
        var bytes = [UInt8](repeating: 0, count: 17)
        bytes[13] = 0x39  // 12345 = 0x3039 in the least significant word
        bytes[14] = 0x30
        XCTAssertEqual(RowDecoder.numeric(bytes, scale: 2), Decimal(string: "123.45"))
        bytes[0] = 0x80
        XCTAssertEqual(RowDecoder.numeric(bytes, scale: 4), Decimal(string: "-1.2345"))
    }

    func testDisplayStrings() {
        XCTAssertEqual(Value.boolean(true).displayString, "Yes")
        XCTAssertEqual(Value.null.displayString, "")
        XCTAssertEqual(Value.double(2).displayString, "2")
        XCTAssertEqual(Value.currency(Decimal(string: "1234.5")!).displayString, "$1,234.50")
    }
}
