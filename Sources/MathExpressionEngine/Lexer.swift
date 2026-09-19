//
//  Lexer.swift
//  MathExpressionEngine
//
//  Single-pass tokenizer. Every token carries a `Span` so diagnostics land at
//  the exact site of a problem.
//

struct Token: Equatable {
    /// The punctuation the lexer reads, spelled by its raw value. Every
    /// operator the engine reads or reports is spelled here and nowhere else:
    /// the scan matches against it, diagnostics name tokens through it, and
    /// `Vocabulary` publishes it for an editor to colour.
    enum Operator: String, CaseIterable {
        case dotDotLess = "..<"
        case dotDot = ".."
        case plus = "+"
        case minus = "-"
        case star = "*"
        case slash = "/"
        case percent = "%"
        case caret = "^"
        case equals = "="
        case semicolon = ";"
        case colon = ":"
        case comma = ","
        case dot = "."
        case lparen = "("
        case rparen = ")"
        case lbracket = "["
        case rbracket = "]"

        /// Brackets are read as a pair around something rather than as an
        /// operator between two things, and an editor pairs them itself.
        var isBracket: Bool {
            switch self {
            case .lparen, .rparen, .lbracket, .rbracket: true
            default: false
            }
        }

        /// Longest first, so a reader matching in order cannot take `..` out of
        /// `..<`. What an editor is handed.
        static let byLengthDescending: [Operator] = allCases.sorted {
            $0.rawValue.count != $1.rawValue.count
                ? $0.rawValue.count > $1.rawValue.count
                : $0.rawValue < $1.rawValue
        }

        // The scan reads these two rather than the raw values, because a raw
        // value is a String and comparing one costs a grapheme walk per
        // candidate per token. Both are built from `allCases` at load, so they
        // are the same list in a shape the lexer can afford.

        /// The one-character spellings, which are all but two of them, indexed
        /// by their byte. Every operator is ASCII, so this is a lookup rather
        /// than a hash.
        static let bySingleCharacter: [Operator?] = {
            var table = [Operator?](repeating: nil, count: 128)
            for op in allCases {
                guard op.rawValue.count == 1,
                      let ascii = op.rawValue.first?.asciiValue
                else { continue }
                table[Int(ascii)] = op
            }
            return table
        }()

        /// The operator a single character spells, if it spells one.
        static func match(_ character: Character) -> Operator? {
            guard let ascii = character.asciiValue else { return nil }
            return bySingleCharacter[Int(ascii)]
        }

        /// The longer spellings, longest first, as characters to compare.
        static let multiCharacter: [(spelling: [Character], op: Operator)] = byLengthDescending
            .filter { $0.rawValue.count > 1 }
            .map { (Array($0.rawValue), $0) }

        /// The longest operator of more than one character spelled at `index`.
        /// Asked before the number rule, because `..` has to beat it while a
        /// lone `.` has to lose to it.
        static func matchLonger(in chars: [Character], at index: Int) -> Operator? {
            for (spelling, op) in multiCharacter {
                // The first character rules almost every position out, and
                // asking costs less than taking a slice to compare.
                guard chars[index] == spelling[0],
                      chars[index...].starts(with: spelling)
                else { continue }
                return op
            }
            return nil
        }
    }

    enum Kind: Equatable {
        case number(Float)
        case identifier(String)
        case op(Operator)
        case eof
    }
    let kind: Kind
    let span: Span
}

struct Lexer {
    /// What starts a comment, which then runs to the end of the line. The
    /// language has line comments only. Written once here and published by
    /// `Vocabulary` for an editor to read.
    static let lineComment: String = "//"

    /// The marker as characters, which is what the scan compares against. Its
    /// first is asked about at every token, so comparing the rest is rare.
    private static let lineCommentCharacters: [Character] = Array(lineComment)

    private let chars: [Character]
    private var i = 0

    init(_ source: String) { self.chars = Array(source) }

    mutating func tokenize() -> (tokens: [Token], diagnostics: [Diagnostic]) {
        var tokens: [Token] = []
        var diagnostics: [Diagnostic] = []

        while i < chars.count {
            let c = chars[i]

            // `isNewline` rather than a list, because a CRLF is one Character
            // and equals neither "\n" nor "\r".
            if c == " " || c == "\t" || c.isNewline {
                i += 1
                continue
            }

            // A comment runs from its marker to the end of the line.
            if c == Self.lineCommentCharacters.first,
               chars[i...].starts(with: Self.lineCommentCharacters) {
                while i < chars.count && !chars[i].isNewline { i += 1 }
                continue
            }

            let start = i

            // Multi-character operators, read before the number and dot rules
            // so the dots of `0..<n` are not taken into the number.
            if let op = Token.Operator.matchLonger(in: chars, at: i) {
                let length = op.rawValue.count
                tokens.append(Token(kind: .op(op), span: Span(start: start, length: length)))
                i += length
                continue
            }

            // Number: digits [ . digits ] [ (e|E) [+|-] digits ]
            // A `.` is consumed only when followed by a digit (so `0..<n` and
            // `p.x` are not swallowed into the number).
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var text = ""
                while i < chars.count {
                    if chars[i].isNumber {
                        text.append(chars[i]); i += 1
                    } else if chars[i] == "." && i + 1 < chars.count && chars[i + 1].isNumber {
                        text.append(chars[i]); i += 1
                    } else {
                        break
                    }
                }
                if i < chars.count && (chars[i] == "e" || chars[i] == "E") {
                    text.append(chars[i]); i += 1
                    if i < chars.count && (chars[i] == "+" || chars[i] == "-") {
                        text.append(chars[i]); i += 1
                    }
                    while i < chars.count && chars[i].isNumber {
                        text.append(chars[i]); i += 1
                    }
                }
                let span = Span(start: start, length: i - start)
                if let value = Float(text) {
                    tokens.append(Token(kind: .number(value), span: span))
                } else {
                    diagnostics.append(Diagnostic(code: .unexpectedToken, severity: .error,
                                                  message: "`\(text)` isn't a valid number.", span: span))
                }
                continue
            }

            // Identifier: [A-Za-z_][A-Za-z0-9_]*
            if c.isLetter || c == "_" {
                var text = ""
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    text.append(chars[i]); i += 1
                }
                tokens.append(Token(kind: .identifier(text), span: Span(start: start, length: i - start)))
                continue
            }

            // Single-character operators and punctuation. Anything longer was
            // offered the chance above, so only a one-character spelling is
            // left to match here.
            if let op = Token.Operator.match(c) {
                tokens.append(Token(kind: .op(op), span: Span(start: start, length: 1)))
                i += 1
            } else {
                diagnostics.append(Diagnostic(code: .unexpectedToken, severity: .error,
                                              message: "Unexpected character `\(c)`.",
                                              span: Span(start: start, length: 1)))
                i += 1
            }
        }

        tokens.append(Token(kind: .eof, span: Span(start: i, length: 0)))
        return (tokens, diagnostics)
    }
}
