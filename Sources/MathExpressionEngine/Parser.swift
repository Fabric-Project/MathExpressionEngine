//
//  Parser.swift
//  MathExpressionEngine
//
//  Recursive-descent / precedence-climbing parser for the expression grammar.
//  Precedence (low→high): + -  |  * / %  |  unary -  |  ^ (right-assoc)  |  call / primary.
//  Unary minus binds looser than `^`, so `-2 ^ 2` == -(2^2) (math convention).
//

struct Parser {
    private let tokens: [Token]
    private var p = 0
    private(set) var diagnostics: [Diagnostic] = []
    private var depth = 0
    // Nesting-depth cap. Each level of nesting costs several stack frames here
    // (additive → multiplicative → unary → power → postfix → primary) and again
    // downstream in Sema / lowering / evaluation, so the cap must keep the whole
    // pipeline's recursion within a small thread/task stack (debug frames are
    // large, and the test runner uses a smaller stack than the main thread).
    // Empirically ~64 levels can exhaust that stack; 32 stays well clear while
    // remaining far beyond any hand-written expression's nesting.
    private let maxDepth = 32

    init(_ tokens: [Token]) { self.tokens = tokens }

    private var current: Token { tokens[p] }

    @discardableResult
    private mutating func advance() -> Token {
        let t = tokens[p]
        if p < tokens.count - 1 { p += 1 }
        return t
    }

    /// Parse a whole function body: `;`-separated statements (`let`/`out`/bare
    /// expression). A single bare expression normalizes to one implicit output.
    mutating func parse() -> Body? {
        if case .eof = current.kind {
            diagnostics.append(Diagnostic(code: .emptyBody, severity: .error,
                                          message: "The function is empty — enter an expression.",
                                          span: current.span))
            return nil
        }

        var items: [ParseItem] = []
        while true {
            guard let item = parseItem() else { return nil }
            items.append(item)

            if case .op(.semicolon) = current.kind {
                advance()
                if case .eof = current.kind { break }   // trailing `;` is fine
                continue
            }
            if case .eof = current.kind { break }

            diagnostics.append(Diagnostic(code: .unexpectedToken, severity: .error,
                                          message: "Expected `;` or end of input after the statement.",
                                          span: current.span))
            return nil
        }

        return normalize(items)
    }

    private mutating func parseItem() -> ParseItem? {
        // Input declaration: `in name: Type`
        if case .identifier(Keyword.in.rawValue) = current.kind {
            let keywordSpan = current.span
            advance()
            guard case .identifier(let name) = current.kind else {
                diagnostics.append(Diagnostic(code: .expectedName, severity: .error,
                                              message: "Expected a name after `in`.", span: current.span))
                return nil
            }
            advance()
            guard case .op(.colon) = current.kind else {
                diagnostics.append(Diagnostic(code: .expectedColon, severity: .error,
                                              message: "Expected `:` and a type after `in \(name)`.", span: current.span))
                return nil
            }
            advance()
            guard let type = parseType() else { return nil }
            return .input(name, type, merge(keywordSpan, current.span))
        }

        if case .identifier(let keyword) = current.kind,
           keyword == Keyword.let.rawValue || keyword == Keyword.out.rawValue {
            let isOutput = (keyword == Keyword.out.rawValue)
            let keywordSpan = current.span
            advance()

            guard case .identifier(let name) = current.kind else {
                diagnostics.append(Diagnostic(code: .expectedName, severity: .error,
                                              message: "Expected a name after `\(keyword)`.",
                                              span: current.span))
                return nil
            }
            advance()

            guard case .op(.equals) = current.kind else {
                diagnostics.append(Diagnostic(code: .expectedEquals, severity: .error,
                                              message: "Expected `=` after `\(keyword) \(name)`.",
                                              span: current.span))
                return nil
            }
            advance()

            guard let value = parseAdditive() else { return nil }
            let span = merge(keywordSpan, value.span)
            return isOutput ? .output(name, value, span) : .local(name, value, span)
        }

        guard let expr = parseAdditive() else { return nil }
        return .expr(expr)
    }

    /// A type annotation: a base type name (`float`, `vec2/3/4`, `transform`,
    /// `quat`) followed by any number of `[]` array suffixes.
    private mutating func parseType() -> ValueType? {
        guard case .identifier(let base) = current.kind else {
            diagnostics.append(Diagnostic(code: .unknownType, severity: .error,
                                          message: "Expected a type name (like `float`, `vec3`, or `vec3[]`).", span: current.span))
            return nil
        }
        let baseSpan = current.span
        guard let named = ValueType.Base(rawValue: base) else {
            diagnostics.append(Diagnostic(code: .unknownType, severity: .error,
                                          message: "Unknown type `\(base)`.", span: baseSpan))
            return nil
        }
        var type = named.type
        advance()
        while case .op(.lbracket) = current.kind {
            advance()
            guard case .op(.rbracket) = current.kind else {
                diagnostics.append(Diagnostic(code: .unknownType, severity: .error,
                                              message: "Expected `]` to close an array type.", span: current.span))
                return nil
            }
            advance()
            type = .array(type)
        }
        return type
    }

    private mutating func normalize(_ items: [ParseItem]) -> Body? {
        let bareExprs: [Expr] = items.compactMap { if case .expr(let e) = $0 { return e } else { return nil } }
        let hasOutput = items.contains { if case .output = $0 { return true } else { return false } }

        if hasOutput && !bareExprs.isEmpty {
            diagnostics.append(Diagnostic(code: .mixedOutput, severity: .error,
                                          message: "A trailing expression can't be combined with `out` declarations — wrap it as `out result = …` or remove it.",
                                          span: bareExprs[0].span))
            return nil
        }
        if !hasOutput && bareExprs.count > 1 {
            diagnostics.append(Diagnostic(code: .mixedOutput, severity: .error,
                                          message: "Multiple expressions without `out` names — give each an `out name = …`.",
                                          span: bareExprs[1].span))
            return nil
        }
        if !hasOutput && bareExprs.isEmpty {
            let span = items.last.map { spanOf($0) } ?? Span(start: 0, length: 0)
            diagnostics.append(Diagnostic(code: .noOutput, severity: .error,
                                          message: "The function produces no output — add a trailing expression or an `out`.",
                                          span: span))
            return nil
        }

        var statements: [Statement] = []
        for item in items {
            switch item {
            case .input(let n, let t, let s):  statements.append(.input(name: n, type: t, span: s))
            case .local(let n, let e, let s):  statements.append(.local(name: n, value: e, span: s))
            case .output(let n, let e, let s): statements.append(.output(name: n, value: e, span: s))
            case .expr(let e):                 statements.append(.output(name: "result", value: e, span: e.span))
            }
        }
        return Body(statements: statements)
    }

    private func spanOf(_ item: ParseItem) -> Span {
        switch item {
        case .input(_, _, let s), .local(_, _, let s), .output(_, _, let s): return s
        case .expr(let e): return e.span
        }
    }

    private mutating func parseAdditive() -> Expr? {
        depth += 1
        defer { depth -= 1 }
        if depth > maxDepth {
            diagnostics.append(Diagnostic(code: .expressionTooDeep, severity: .error,
                                          message: "Expression is nested too deeply.", span: current.span))
            return nil
        }
        guard var left = parseMultiplicative() else { return nil }
        while true {
            let op: BinaryOp
            switch current.kind {
            case .op(.plus):  op = .add
            case .op(.minus): op = .sub
            default:     return left
            }
            advance()
            guard let right = parseMultiplicative() else { return nil }
            left = .binary(op, left, right, merge(left.span, right.span))
        }
    }

    private mutating func parseMultiplicative() -> Expr? {
        guard var left = parseUnary() else { return nil }
        while true {
            let op: BinaryOp
            switch current.kind {
            case .op(.star):    op = .mul
            case .op(.slash):   op = .div
            case .op(.percent): op = .mod
            default:       return left
            }
            advance()
            guard let right = parseUnary() else { return nil }
            left = .binary(op, left, right, merge(left.span, right.span))
        }
    }

    private mutating func parseUnary() -> Expr? {
        if case .op(.minus) = current.kind {
            let s = current.span
            advance()
            guard let operand = parseUnary() else { return nil }
            return .negate(operand, merge(s, operand.span))
        }
        if case .op(.plus) = current.kind {          // unary plus: no-op
            advance()
            return parseUnary()
        }
        return parsePower()
    }

    private mutating func parsePower() -> Expr? {
        guard let base = parsePostfix() else { return nil }
        if case .op(.caret) = current.kind {
            advance()
            // Right operand is a unary so `2 ^ -3` parses; recursion gives right-assoc.
            guard let exponent = parseUnary() else { return nil }
            return .binary(.pow, base, exponent, merge(base.span, exponent.span))
        }
        return base
    }

    // Postfix: primary followed by any number of `.swizzle` or `[index]` accesses.
    private mutating func parsePostfix() -> Expr? {
        guard var expr = parsePrimary() else { return nil }
        while true {
            if case .op(.dot) = current.kind {
                advance()
                guard case .identifier(let chars) = current.kind else {
                    diagnostics.append(Diagnostic(code: .badSwizzle, severity: .error,
                                                  message: "Expected a swizzle like `.x` or `.xyz` after `.`.",
                                                  span: current.span))
                    return nil
                }
                let span = merge(expr.span, current.span)
                advance()
                expr = .swizzle(expr, chars, span)
            } else if case .op(.lbracket) = current.kind {
                advance()
                guard let idx = parseAdditive() else { return nil }
                guard case .op(.rbracket) = current.kind else {
                    diagnostics.append(Diagnostic(code: .unmatchedParen, severity: .error,
                                                  message: "Expected `]` to close the index.", span: current.span))
                    return nil
                }
                let span = merge(expr.span, current.span)
                advance()
                expr = .index(expr, idx, span)
            } else {
                break
            }
        }
        return expr
    }

    /// `[` … `]` — an array literal `[a, b, c]` or a comprehension
    /// `[body for i in lo..<hi]`.
    private mutating func parseBracketed() -> Expr? {
        let startSpan = current.span
        advance()   // consume `[`

        if case .op(.rbracket) = current.kind {
            diagnostics.append(Diagnostic(code: .emptyArray, severity: .error,
                                          message: "An empty array `[]` has no element type — add at least one element.",
                                          span: startSpan))
            return nil
        }

        guard let first = parseAdditive() else { return nil }

        // Comprehension over a range `[ body for i in lo (.. | ..<) hi ]`, or
        // over an array `[ body for p in arrayExpr ]`.
        if case .identifier(Keyword.for.rawValue) = current.kind {
            advance()

            // Loop pattern: a single name, or an enumerate pair `(index, element)`.
            var indexVar: String? = nil
            let elemVar: String
            if case .op(.lparen) = current.kind {
                advance()
                guard case .identifier(let iv) = current.kind else {
                    diagnostics.append(Diagnostic(code: .expectedName, severity: .error,
                                                  message: "Expected an index name in the `(index, element)` pattern.", span: current.span))
                    return nil
                }
                advance()
                guard case .op(.comma) = current.kind else {
                    diagnostics.append(Diagnostic(code: .expectedName, severity: .error,
                                                  message: "Expected `,` between the index and element names.", span: current.span))
                    return nil
                }
                advance()
                guard case .identifier(let ev) = current.kind else {
                    diagnostics.append(Diagnostic(code: .expectedName, severity: .error,
                                                  message: "Expected an element name in the `(index, element)` pattern.", span: current.span))
                    return nil
                }
                advance()
                guard case .op(.rparen) = current.kind else {
                    diagnostics.append(Diagnostic(code: .unmatchedParen, severity: .error,
                                                  message: "Expected `)` to close the `(index, element)` pattern.", span: current.span))
                    return nil
                }
                advance()
                indexVar = iv; elemVar = ev
            } else {
                guard case .identifier(let lv) = current.kind else {
                    diagnostics.append(Diagnostic(code: .expectedName, severity: .error,
                                                  message: "Expected a loop variable after `for`.", span: current.span))
                    return nil
                }
                advance()
                elemVar = lv
            }

            guard case .identifier(Keyword.in.rawValue) = current.kind else {
                diagnostics.append(Diagnostic(code: .expectedName, severity: .error,
                                              message: "Expected `in` after the loop variable.", span: current.span))
                return nil
            }
            advance()
            guard let source = parseAdditive() else { return nil }

            // A `..`/`..<` here means a numeric range; otherwise `source` is the
            // array being iterated.
            let inclusive: Bool
            if case .op(.dotDotLess) = current.kind { inclusive = false; advance() }
            else if case .op(.dotDot) = current.kind { inclusive = true; advance() }
            else {
                guard case .op(.rbracket) = current.kind else {
                    diagnostics.append(Diagnostic(code: .unmatchedParen, severity: .error,
                                                  message: "Expected `]` to close the comprehension.", span: current.span))
                    return nil
                }
                let span = merge(startSpan, current.span)
                advance()
                return .mapComprehension(body: first, indexVar: indexVar, elemVar: elemVar, source: source, span)
            }

            // A numeric range already exposes its index, so the enumerate pattern
            // is meaningless here.
            if indexVar != nil {
                diagnostics.append(Diagnostic(code: .expectedRange, severity: .error,
                                              message: "An `(index, element)` pattern iterates an array — use a single name for a numeric range.",
                                              span: merge(startSpan, current.span)))
                return nil
            }

            guard let hi = parseAdditive() else { return nil }
            guard case .op(.rbracket) = current.kind else {
                diagnostics.append(Diagnostic(code: .unmatchedParen, severity: .error,
                                              message: "Expected `]` to close the comprehension.", span: current.span))
                return nil
            }
            let span = merge(startSpan, current.span)
            advance()
            return .comprehension(body: first, loopVar: elemVar, lo: source, hi: hi, inclusive: inclusive, span)
        }

        // Array literal: `[ first (, expr)* ]`
        var elements = [first]
        while case .op(.comma) = current.kind {
            advance()
            guard let e = parseAdditive() else { return nil }
            elements.append(e)
        }
        guard case .op(.rbracket) = current.kind else {
            diagnostics.append(Diagnostic(code: .unmatchedParen, severity: .error,
                                          message: "Expected `]` to close the array.", span: current.span))
            return nil
        }
        let span = merge(startSpan, current.span)
        advance()
        return .arrayLiteral(elements, span)
    }

    private mutating func parsePrimary() -> Expr? {
        switch current.kind {
        case .number(let value):
            let s = current.span; advance()
            return .number(value, s)

        case .identifier(let name):
            let s = current.span; advance()
            if case .op(.lparen) = current.kind {
                advance()
                var args: [Expr] = []
                if case .op(.rparen) = current.kind {
                    // zero-argument call
                } else {
                    while true {
                        guard let arg = parseAdditive() else { return nil }
                        args.append(arg)
                        if case .op(.comma) = current.kind { advance(); continue }
                        break
                    }
                }
                guard case .op(.rparen) = current.kind else {
                    diagnostics.append(Diagnostic(code: .unmatchedParen, severity: .error,
                                                  message: "Expected `)` to close `\(name)(`.",
                                                  span: current.span))
                    return nil
                }
                let end = current.span; advance()
                return .call(name, args, merge(s, end))
            }
            // Inline typed input: `name: Type` (e.g. `p: vec3`).
            if case .op(.colon) = current.kind {
                advance()
                guard let type = parseType() else { return nil }
                return .typedVariable(name, type, merge(s, current.span))
            }
            return .variable(name, s)

        case .op(.lparen):
            advance()
            guard let inner = parseAdditive() else { return nil }
            guard case .op(.rparen) = current.kind else {
                diagnostics.append(Diagnostic(code: .unmatchedParen, severity: .error,
                                              message: "Expected `)`.", span: current.span))
                return nil
            }
            advance()
            return inner

        case .op(.lbracket):
            return parseBracketed()

        case .eof:
            diagnostics.append(Diagnostic(code: .incompleteExpression, severity: .error,
                                          message: "The expression is incomplete.", span: current.span))
            return nil

        default:
            diagnostics.append(Diagnostic(code: .unexpectedToken, severity: .error,
                                          message: "Unexpected `\(describe(current))`.", span: current.span))
            return nil
        }
    }
}

/// A parsed statement before normalization into `Body`.
private enum ParseItem {
    case input(String, ValueType, Span)
    case local(String, Expr, Span)
    case output(String, Expr, Span)
    case expr(Expr)
}

/// The words the parser reads as structure rather than as a name. Spelled by
/// their raw values, which is the only place they are written: the parser
/// matches through them and `Vocabulary` publishes them for an editor.
enum Keyword: String, CaseIterable {
    case `in`, out, `let`, `for`
}

private func merge(_ a: Span, _ b: Span) -> Span {
    let start = min(a.start, b.start)
    let end = max(a.start + a.length, b.start + b.length)
    return Span(start: start, length: end - start)
}

private func describe(_ t: Token) -> String {
    switch t.kind {
    case .number(let v):     return "\(v)"
    case .identifier(let s): return s
    case .op(let op):        return op.rawValue
    case .eof:               return "end of input"
    }
}
