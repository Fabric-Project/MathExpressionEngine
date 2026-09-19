import Testing
import Foundation
@testable import MathExpressionEditorSupport
import LanguageSupport
import MathExpressionEngine

/// The editor's view of the expression language.
///
/// Every word in the configuration comes from the engine rather than a list
/// kept here, which is the point: a function added to the engine has to colour
/// without anyone editing Fabric. These check that it does, and that the
/// language's own oddities — a range operator that starts with a dot, no
/// comparisons at all — survive the regexes.
@Suite("Math Expression language")
struct MathExpressionLanguageTests
{
    private var configuration: LanguageConfiguration { .mathExpressionLanguage() }

    @Test("Every name the engine knows is a reserved word here")
    func theEngineSuppliesTheVocabulary() throws
    {
        let reserved = Set(self.configuration.reservedIdentifiers)

        for name in Vocabulary.functions
        {
            #expect(reserved.contains(name), "`\(name)` is callable but would not colour")
        }
        for name in Vocabulary.constants + Vocabulary.typeNames + Vocabulary.keywords
        {
            #expect(reserved.contains(name), "`\(name)` is part of the language but would not colour")
        }
    }

    @Test("Nothing is reserved that the engine does not know")
    func nothingIsInventedHere() throws
    {
        let known = Set(Vocabulary.functions + Vocabulary.constants
                        + Vocabulary.typeNames + Vocabulary.keywords)

        for name in self.configuration.reservedIdentifiers
        {
            #expect(known.contains(name), "`\(name)` colours but the engine has never heard of it")
        }
    }

    @Test("The language has no strings and no character literals")
    func thereIsNothingToQuote() throws
    {
        #expect(self.configuration.stringRegex == nil)
        #expect(self.configuration.characterRegex == nil)
    }

    @Test("Statements are separated, not nested")
    func thereAreNoBlocks() throws
    {
        #expect(self.configuration.supportsSquareBrackets)
        #expect(self.configuration.supportsCurlyBrackets == false)
        #expect(self.configuration.nestedComment == nil)
        #expect(self.configuration.singleLineComment == Vocabulary.lineComment)
    }

    // MARK: - The regexes, against the language's awkward parts

    private func matches(_ regex: Regex<Substring>?, _ text: String) -> String?
    {
        guard let regex, let match = try? regex.firstMatch(in: text) else { return nil }
        return String(match.output)
    }

    @Test("A number does not swallow the dot of a range")
    func aRangeIsNotANumber() throws
    {
        // `0..<n` has to lex as `0` then `..<`, not as `0.` and a stray `.`.
        #expect(self.matches(self.configuration.numberRegex, "0..<n") == "0")
        #expect(self.matches(self.configuration.numberRegex, "1.5") == "1.5")
        #expect(self.matches(self.configuration.numberRegex, "2e-3") == "2e-3")
    }

    @Test("The range operators match before the dot")
    func rangesMatchWholeAndLongestFirst() throws
    {
        #expect(self.matches(self.configuration.operatorRegex, "..<") == "..<")
        #expect(self.matches(self.configuration.operatorRegex, "..") == "..")
        #expect(self.matches(self.configuration.operatorRegex, ".") == ".")
    }

    /// The pattern is built from the published list rather than written out, so
    /// what has to be checked is that building it worked: a bad escape leaves
    /// `operatorRegex` nil and every operator silently stops colouring.
    @Test("Every operator the engine publishes matches, whole")
    func theEngineSuppliesTheOperators() throws
    {
        let regex = try #require(self.configuration.operatorRegex,
                                 "the pattern built from the vocabulary did not compile")

        for spelling in Vocabulary.operators
        {
            #expect(self.matches(regex, spelling) == spelling,
                    "`\(spelling)` is published but does not match whole")
        }
    }

    @Test("An alternation escapes what a regex would read, and nothing else")
    func alternationsAreEscapedNarrowly() throws
    {
        #expect(LanguageConfiguration.alternation(of: ["..<", ".."]) == #"\.\.<|\.\."#)
        #expect(LanguageConfiguration.alternation(of: ["+", "-", "^"]) == #"\+|\-|\^"#)
        // `<`, `:`, `;`, `=`, `%` and `,` are literals in a regex, so they are
        // left as they are.
        #expect(LanguageConfiguration.alternation(of: [":", ";", "=", "%", ","]) == ":|;|=|%|,")
    }

    @Test("An identifier is a name, and ends where a name ends")
    func identifiersAreNames() throws
    {
        #expect(self.matches(self.configuration.identifierRegex, "radius") == "radius")
        #expect(self.matches(self.configuration.identifierRegex, "_x2") == "_x2")
        // `$` is a name character in JavaScript and not in this language.
        #expect(self.matches(self.configuration.identifierRegex, "a$b") == "a")
    }
}
