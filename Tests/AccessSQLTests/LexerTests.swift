import XCTest
@testable import AccessSQL

final class LexerTests: XCTestCase {
    func testSelectWithAccessSyntax() throws {
        let tokens = try Lexer.tokenize(
            "SELECT TOP 10 [Order ID], o.Total FROM [Order Details] AS o WHERE o.Shipped >= #1/2/2024# AND Name LIKE 'O''Brien*';")
        XCTAssertEqual(tokens, [
            .keyword("SELECT"), .keyword("TOP"), .number("10"), .bracketedIdentifier("Order ID"), .symbol(","),
            .identifier("o"), .symbol("."), .identifier("Total"), .keyword("FROM"),
            .bracketedIdentifier("Order Details"), .keyword("AS"), .identifier("o"), .keyword("WHERE"),
            .identifier("o"), .symbol("."), .identifier("Shipped"), .symbol(">="), .date("1/2/2024"),
            .keyword("AND"), .identifier("Name"), .keyword("LIKE"), .string("O'Brien*"), .symbol(";"),
        ])
    }

    func testNumbersStringsAndOperators() throws {
        XCTAssertEqual(try Lexer.tokenize("1.5e3 <> .25 & \"a\"\"b\""), [
            .number("1.5e3"), .symbol("<>"), .number(".25"), .symbol("&"), .string("a\"b"),
        ])
        XCTAssertEqual(try Lexer.tokenize("select -- comment\n x"), [.keyword("SELECT"), .identifier("x")])
    }

    func testErrors() {
        XCTAssertThrowsError(try Lexer.tokenize("SELECT [unterminated")) { error in
            XCTAssertEqual((error as? LexerError)?.offset, 7)
        }
        XCTAssertThrowsError(try Lexer.tokenize("SELECT 'abc"))
        XCTAssertThrowsError(try Lexer.tokenize("SELECT @x"))
    }
}
