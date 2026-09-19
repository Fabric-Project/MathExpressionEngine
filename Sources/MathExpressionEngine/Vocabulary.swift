//
//  Vocabulary.swift
//  MathExpressionEngine
//
//  The words the language knows, for an editor to colour and offer. Derived
//  from the same tables the lexer, parser and evaluator work from, so an editor
//  built on this cannot fall behind the language it is editing.
//

/// The names that mean something to the engine, for a host that highlights or
/// completes expressions.
public enum Vocabulary {

    /// Words the parser reads as structure rather than as a name.
    public static let keywords: [String] = Keyword.allCases.map(\.rawValue)

    /// Base type names an `in` declaration annotates with. Any of them takes any
    /// number of `[]` suffixes.
    public static let typeNames: [String] = ValueType.Base.allCases.map(\.rawValue)

    /// Names that already have a value.
    public static let constants: [String] = Builtins.constants.keys.sorted()

    /// Names that can be called, including the vector constructors.
    public static let functions: [String] = (Builtins.arities.keys + constructors).sorted()

    /// Vector constructors, which take their width from their name rather than
    /// from an arity table. The vector types are exactly the ones that construct.
    public static let constructors: [String] =
        ValueType.Base.allCases.filter { $0.type.isVector }.map(\.rawValue)

    /// Every name above, for a host that does not care which kind it is. A
    /// vector type is also a constructor, so the two lists overlap and this is
    /// the union rather than the concatenation.
    public static let allNames: [String] =
        Set(keywords + typeNames + constants + functions).sorted()

    /// How many arguments a call to `name` is ordinarily written with, or nil
    /// if the name is not a function. A vector constructor takes as many as its
    /// width.
    ///
    /// This is one number, and a few names accept more than one shape: `min`
    /// and `max` also reduce a single array, and a constructor also splats a
    /// single float. Labelling a completion with it is fine; rejecting a call
    /// on it is not.
    public static func arity(of name: String) -> Int? {
        if let arity = Builtins.arities[name] { return arity }
        return ValueType.Base.constructed(name)?.width
    }

    /// Every operator the lexer reads, and no more: the language has no
    /// comparisons and no logical operators, which is not what anything
    /// arithmetic-looking suggests. Longest first, so a host matching in order
    /// cannot take `..` out of `..<`.
    ///
    /// Brackets are left out — an editor pairs those itself.
    public static let operators: [String] = Token.Operator.byLengthDescending
        .filter { !$0.isBracket }
        .map(\.rawValue)

    /// What starts a comment. The language has line comments only, ended by
    /// any newline.
    public static let lineComment: String = Lexer.lineComment
}
