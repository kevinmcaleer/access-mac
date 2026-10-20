/// A token of Access SQL.
public enum Token: Equatable, Sendable {
    /// A bare name; `keyword` holds its upper-cased form when it is reserved.
    case identifier(String)
    /// A `[bracketed name]`, which may contain spaces and punctuation.
    case bracketedIdentifier(String)
    case keyword(String)
    case string(String)
    case number(String)
    /// A `#date#` literal, kept as written between the hashes.
    case date(String)
    case symbol(String)
}

public struct LexerError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "\(message) at character \(offset + 1)" }
}

/// Splits Access SQL into tokens. Access differs from ANSI SQL in a few ways
/// handled here: `[ ]` quotes names, `#` delimits dates, both `'` and `"`
/// quote strings (doubling the quote escapes it), and `*`/`?` wildcards in
/// LIKE patterns are ordinary string content.
public struct Lexer {
    public static let keywords: Set<String> = [
        "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "BETWEEN", "BY", "COLUMN", "CONSTRAINT", "CREATE",
        "DELETE", "DESC", "DISTINCT", "DISTINCTROW", "DROP", "EXISTS", "FROM", "FULL", "GROUP", "HAVING",
        "IN", "INDEX", "INNER", "INSERT", "INTO", "IS", "JOIN", "KEY", "LEFT", "LIKE", "MOD", "NOT", "NULL",
        "ON", "OR", "ORDER", "OUTER", "PARAMETERS", "PERCENT", "PIVOT", "PRIMARY", "REFERENCES", "RIGHT",
        "SELECT", "SET", "SOME", "TABLE", "TOP", "TRANSFORM", "UNION", "UNIQUE", "UPDATE", "VALUES",
        "WHERE", "WITH", "XOR", "EQV", "IMP",
    ]

    public static func tokenize(_ text: String) throws -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var i = 0

        func read(until close: Character, from start: Int, what: String) throws -> String {
            var j = start + 1
            while j < chars.count, chars[j] != close { j += 1 }
            guard j < chars.count else { throw LexerError(message: "Unterminated \(what)", offset: start) }
            defer { i = j + 1 }
            return String(chars[(start + 1)..<j])
        }

        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
            } else if c == "-" && i + 1 < chars.count && chars[i + 1] == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if c == "[" {
                tokens.append(.bracketedIdentifier(try read(until: "]", from: i, what: "bracketed name")))
            } else if c == "#" {
                tokens.append(.date(try read(until: "#", from: i, what: "date literal")))
            } else if c == "'" || c == "\"" {
                var value = ""
                var j = i + 1
                var closed = false
                while j < chars.count {
                    if chars[j] == c {
                        if j + 1 < chars.count, chars[j + 1] == c {
                            value.append(c)
                            j += 2
                            continue
                        }
                        closed = true
                        break
                    }
                    value.append(chars[j])
                    j += 1
                }
                guard closed else { throw LexerError(message: "Unterminated string", offset: i) }
                tokens.append(.string(value))
                i = j + 1
            } else if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                if j < chars.count, chars[j] == "E" || chars[j] == "e" {
                    var k = j + 1
                    if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
                    if k < chars.count, chars[k].isNumber {
                        j = k
                        while j < chars.count, chars[j].isNumber { j += 1 }
                    }
                }
                tokens.append(.number(String(chars[i..<j])))
                i = j
            } else if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                let upper = word.uppercased()
                tokens.append(keywords.contains(upper) ? .keyword(upper) : .identifier(word))
                i = j
            } else {
                let two = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
                if ["<>", "<=", ">="].contains(two) {
                    tokens.append(.symbol(two))
                    i += 2
                } else if "=<>+-*/\\^&(),.;!?:".contains(c) {
                    tokens.append(.symbol(String(c)))
                    i += 1
                } else {
                    throw LexerError(message: "Unexpected character \"\(c)\"", offset: i)
                }
            }
        }
        return tokens
    }
}
