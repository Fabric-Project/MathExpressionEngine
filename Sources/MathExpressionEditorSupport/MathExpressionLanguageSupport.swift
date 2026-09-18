//
//  MathExpressionLanguageSupport.swift
//  MathExpressionEditorSupport
//

import LanguageSupport
import MathExpressionEngine

extension LanguageConfiguration
{
    /// A regular expression alternation matching any of `spellings`, in the
    /// order given. The engine publishes its operators longest first so that
    /// `..<` is offered before `..`, and an alternation is tried in order, so
    /// keeping that order is what stops `..<` lexing as `..` and a stray `<`.
    public static func alternation(of spellings: [String]) -> String
    {
        // Escaping is by list rather than blanket, because a blanket escape of
        // every character would be wrong for a letter: `\w`, `\d` and `\b` mean
        // something. Punctuation that is already a literal is left as it is.
        let metacharacters: Set<Character> = ["\\", ".", "^", "$", "*", "+", "?",
                                              "(", ")", "[", "]", "{", "}", "|", "/", "-"]

        return spellings
            .map { spelling in
                spelling.map { metacharacters.contains($0) ? "\\\($0)" : String($0) }.joined()
            }
            .joined(separator: "|")
    }

    /// Every word comes from the engine, so a function added there colours here
    /// without anyone remembering to add it twice.
    public static func mathExpressionLanguage(_ languageService: LanguageService? = nil) -> LanguageConfiguration
    {
        // `..` and `..<` are read before a number, so a number never takes a
        // trailing dot and leaves a lone `.` behind it.
        let numberRegex = try? Regex<Substring>(#"\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)
        let identifierRegex = try? Regex<Substring>(#"[A-Za-z_][A-Za-z0-9_]*"#)
        let operatorRegex = try? Regex<Substring>(Self.alternation(of: Vocabulary.operators))

        return LanguageConfiguration(
            name: "Math Expression",
            supportsSquareBrackets: true,
            // The language has no blocks: statements are separated by `;`.
            supportsCurlyBrackets: false,
            stringRegex: nil,
            characterRegex: nil,
            numberRegex: numberRegex,
            singleLineComment: Vocabulary.lineComment,
            nestedComment: nil,
            identifierRegex: identifierRegex,
            operatorRegex: operatorRegex,
            reservedIdentifiers: Vocabulary.keywords
                + Vocabulary.typeNames
                + Vocabulary.constants
                + Vocabulary.functions,
            reservedOperators: Vocabulary.operators,
            languageService: languageService
        )
    }
}
