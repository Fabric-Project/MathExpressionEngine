import Testing
@testable import MathExpressionEngine

/// The vocabulary is what an editor colours and offers, and it is only worth
/// publishing if it cannot fall behind the language. These check it against the
/// tables the engine itself works from, and against the engine compiling.
@Suite struct VocabularyTests {

    /// Holds by construction — `Vocabulary` reads these tables — and is here to
    /// keep it that way, so publishing never becomes a list someone maintains.
    @Test func everyFunctionTheEngineKnowsIsPublished() {
        for name in Builtins.arities.keys {
            #expect(Vocabulary.functions.contains(name), "`\(name)` is callable but not published")
        }
        for name in Builtins.constants.keys {
            #expect(Vocabulary.constants.contains(name), "`\(name)` is a constant but not published")
        }
    }

    /// Checked against the engine rather than against the list it was built
    /// from: a name an editor offers has to be one the engine will dispatch.
    ///
    /// Calling at the published arity is not expected to compile — many of
    /// these want a quat, a transform or an array, and this deliberately does
    /// not restate their signatures. What it asserts is that the complaint is
    /// about the arguments and never about the name, because a complaint about
    /// the arguments is proof the call was dispatched.
    @Test func everyPublishedFunctionIsOneTheEngineDispatches() throws {
        for name in Vocabulary.functions {
            let arity = try #require(Vocabulary.arity(of: name), "`\(name)` is published with no arity")
            let arguments = Array(repeating: "1", count: arity).joined(separator: ", ")

            let result = compile("out y = \(name)(\(arguments))")
            let isUnknown = result.diagnostics.contains { $0.message.contains("Unknown function") }
            #expect(isUnknown == false,
                    "`\(name)` is published but the engine does not know it: \(result.diagnostics)")
        }
    }

    @Test func everyPublishedConstantHasAValue() {
        for name in Vocabulary.constants {
            let result = compile("out y = \(name)")
            #expect(result.isValid,
                    "`\(name)` is published as a constant but does not compile: \(result.diagnostics)")
        }
    }

    @Test func everyPublishedNameLexesAsOneIdentifier() {
        for name in Vocabulary.keywords + Vocabulary.typeNames + Vocabulary.constants + Vocabulary.functions {
            var lexer = Lexer(name)
            let (tokens, diagnostics) = lexer.tokenize()
            #expect(diagnostics.isEmpty, "`\(name)` does not lex")
            // The identifier, then eof.
            #expect(tokens.count == 2, "`\(name)` is not a single token")
            #expect(tokens.first?.kind == .identifier(name), "`\(name)` is not an identifier")
        }
    }

    /// A type name is only a type where a declaration expects one, so the check
    /// is that the engine accepts it there — and annotates with the type the
    /// name is supposed to mean. A `Base` case wired to the wrong `ValueType`
    /// would compile and pass every other test in this file.
    @Test func everyPublishedTypeAnnotatesAnInputWithItself() throws {
        for base in ValueType.Base.allCases {
            let result = compile("in x: \(base.rawValue); out y = 0")
            #expect(result.isValid,
                    "`\(base.rawValue)` is published as a type but does not annotate: \(result.diagnostics)")
            #expect(result.interface.inputs.first?.type == base.type,
                    "`\(base.rawValue)` annotates as \(String(describing: result.interface.inputs.first?.type))")
            #expect(base.type.name == base.rawValue,
                    "`\(base.rawValue)` reports its name as `\(base.type.name)`")
        }
    }

    @Test func everyTypeAndKeywordIsPublished() {
        #expect(Vocabulary.typeNames == ValueType.Base.allCases.map(\.rawValue))
        #expect(Vocabulary.keywords == Keyword.allCases.map(\.rawValue))

        for name in Vocabulary.typeNames {
            #expect(ValueType.Base(rawValue: name) != nil, "`\(name)` is published but is not a type")
        }
        for name in Vocabulary.keywords {
            #expect(Keyword(rawValue: name) != nil, "`\(name)` is published but is not a keyword")
        }
    }

    /// The constructors are the vector types, and each takes as many arguments
    /// as its width. Read from the types rather than listed.
    @Test func everyVectorTypeConstructsAtItsOwnWidth() {
        for base in ValueType.Base.allCases where base.type.isVector {
            #expect(Vocabulary.constructors.contains(base.rawValue),
                    "`\(base.rawValue)` is a vector type but does not construct")
            #expect(Vocabulary.arity(of: base.rawValue) == base.type.width,
                    "`\(base.rawValue)` constructs at the wrong width")

            let arguments = (1...base.type.width).map(String.init).joined(separator: ", ")
            let result = compile("out y = \(base.rawValue)(\(arguments))")
            #expect(result.isValid, "`\(base.rawValue)` does not construct: \(result.diagnostics)")
            #expect(result.interface.outputType == base.type)
        }
    }

    /// The operators are the enum's raw values, so the two cannot disagree. What
    /// can still be wrong is an operator the scan never reaches, because an
    /// earlier rule eats its first character.
    @Test func everyOperatorLexesAsItself() {
        for op in Token.Operator.allCases {
            var lexer = Lexer(op.rawValue)
            let (tokens, diagnostics) = lexer.tokenize()
            #expect(diagnostics.isEmpty, "`\(op.rawValue)` does not lex")
            #expect(tokens.count == 2, "`\(op.rawValue)` is not a single token")
            #expect(tokens.first?.kind == .op(op), "`\(op.rawValue)` lexes as something else")
        }
    }

    @Test func everyOperatorIsPublishedUnlessItIsABracket() {
        for op in Token.Operator.allCases where !op.isBracket {
            #expect(Vocabulary.operators.contains(op.rawValue),
                    "`\(op.rawValue)` is an operator but not published")
        }
        for spelling in Vocabulary.operators {
            let op = Token.Operator(rawValue: spelling)
            #expect(op != nil, "`\(spelling)` is published but the lexer does not read it")
            #expect(op?.isBracket == false, "`\(spelling)` is a bracket, and an editor pairs those itself")
        }
    }

    /// A host matches in the order given, so `..<` has to be offered before `..`.
    @Test func operatorsArePublishedLongestFirst() {
        let lengths = Vocabulary.operators.map(\.count)
        #expect(lengths == lengths.sorted(by: >), "\(Vocabulary.operators)")
    }

    /// The marker is published from the lexer, so what this checks is that the
    /// published one is the one that works: everything after it is skipped
    /// rather than merely tolerated, and the next line is read as usual.
    @Test func aCommentRunsToTheEndOfTheLine() {
        let skipped = compile("out y = 1 \(Vocabulary.lineComment) £ @ not lexed at all")
        #expect(skipped.isValid, "\(skipped.diagnostics)")

        // The `;` is the separator, not the newline, so it goes before the comment.
        let nextLine = compile("out y = 1; \(Vocabulary.lineComment) ignored\nout z = 2")
        #expect(nextLine.isValid, "\(nextLine.diagnostics)")
        #expect(nextLine.interface.outputs.count == 2)
    }

}
