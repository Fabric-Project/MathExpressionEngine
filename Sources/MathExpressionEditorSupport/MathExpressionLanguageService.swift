//
//  MathExpressionLanguageService.swift
//  MathExpressionEditorSupport
//

import Combine
import Foundation
import LanguageSupport
import MathExpressionEngine
import SwiftUI

private struct MathExpressionCompletionEntry
{
    enum Kind: String
    {
        case keyword
        case type
        case constant
        case function
        case input
        case output
    }

    let label: String
    let insertText: String
    let documentation: String
    let kind: Kind
    let priority: Int
}

/// Completions for the Math Expression editor.
///
/// What the language knows comes from the engine, so this offers whatever the
/// engine can evaluate. What the expression knows — the names an `in`, `out` or
/// `let` has declared — is read back out of the text as it is edited, so the
/// names already in play are offered alongside.
public final class MathExpressionLanguageService: LanguageService
{
    public init() {}

    public var isOpen: Bool = false
    public let events = PassthroughSubject<LanguageServiceEvent, Never>()
    public let diagnostics = CurrentValueSubject<Set<TextLocated<Message>>, Never>([])
    public let completionTriggerCharacters = CurrentValueSubject<[Character], Never>([])
    public let extraActions = CurrentValueSubject<[ExtraAction], Never>([])

    private var documentText: String = ""
    private var locationService: LocationService?

    private static let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    // MARK: - What the language offers

    private static let languageEntries: [MathExpressionCompletionEntry] = {
        let keywords = Vocabulary.keywords.map { keyword in
            MathExpressionCompletionEntry(
                label: keyword,
                insertText: keyword,
                documentation: MathExpressionLanguageService.documentation(forKeyword: keyword),
                kind: .keyword,
                priority: 400)
        }

        let types = Vocabulary.typeNames.map { type in
            MathExpressionCompletionEntry(
                label: type,
                insertText: type,
                documentation: "A value of type `\(type)`. `\(type)[]` for an array of them.",
                kind: .type,
                priority: 350)
        }

        let constants = Vocabulary.constants.map { constant in
            MathExpressionCompletionEntry(
                label: constant,
                insertText: constant,
                documentation: "Constant.",
                kind: .constant,
                priority: 300)
        }

        let functions = Vocabulary.functions.map { function in
            let arity = Vocabulary.arity(of: function) ?? 0
            return MathExpressionCompletionEntry(
                label: function,
                insertText: arity == 0 ? "\(function)()" : "\(function)(",
                documentation: arity == 1 ? "Takes one argument." : "Takes \(arity) arguments.",
                kind: .function,
                priority: 250)
        }

        return keywords + types + constants + functions
    }()

    private static func documentation(forKeyword keyword: String) -> String
    {
        switch keyword
        {
        case "in": "Declares an input port: `in name: type`."
        case "out": "Declares an output port: `out name = …`."
        case "let": "Names a value for use further down: `let name = …`."
        case "for": "Generates an array: `[ … for i in 0..<n ]`."
        default: "Keyword."
        }
    }

    // MARK: - Document

    public func openDocument(with text: String, locationService: LocationService) async throws
    {
        self.documentText = text
        self.locationService = locationService
        self.isOpen = true
    }

    public func documentDidChange(position changeLocation: Int,
                           changeInLength delta: Int,
                           lineChange deltaLine: Int,
                           columnChange deltaColumn: Int,
                           newText text: String) async throws
    {
        let nsText = self.documentText as NSString
        let replacedLength = max(0, text.utf16.count - delta)
        let replaceRange = NSRange(location: changeLocation, length: replacedLength)

        if NSMaxRange(replaceRange) <= nsText.length
        {
            self.documentText = nsText.replacingCharacters(in: replaceRange, with: text)
        }
        else
        {
            self.documentText = text
        }
    }

    public func closeDocument() async throws
    {
        self.documentText = ""
        self.locationService = nil
        self.isOpen = false
    }

    // MARK: - Completions

    public func completions(at location: Int, reason: CompletionTriggerReason) async throws -> Completions
    {
        let nsText = self.documentText as NSString
        let clampedLocation = min(max(0, location), nsText.length)

        let insertRange = self.identifierRange(at: clampedLocation)
        let prefix = nsText.substring(with: NSRange(location: insertRange.location,
                                                    length: clampedLocation - insertRange.location))

        let entries = self.declaredEntries() + Self.languageEntries
        let filtered = entries
            .filter { prefix.isEmpty || $0.label.hasPrefix(prefix) }
            .sorted { $0.priority == $1.priority ? $0.label < $1.label : $0.priority > $1.priority }

        let items = filtered.enumerated().map { index, entry in
            Completions.Completion(
                id: index,
                rowView: { selected in
                    Text("\(entry.label)  \(entry.kind.rawValue)")
                        .font(.caption.monospaced())
                        .foregroundStyle(selected ? .primary : .secondary)
                },
                documentationView: Text(entry.documentation)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading),
                selected: index == 0,
                sortText: "\(999 - entry.priority)-\(entry.label)",
                filterText: entry.label,
                insertText: entry.insertText,
                insertRange: insertRange,
                commitCharacters: [",", ":", "(", " "],
                refine: { nil }
            )
        }

        return Completions(isIncomplete: false, items: items)
    }

    /// The names this expression has declared for itself.
    private func declaredEntries() -> [MathExpressionCompletionEntry]
    {
        var entries: [MathExpressionCompletionEntry] = []
        var seen = Set<String>()

        for (keyword, kind, documentation) in [("in", MathExpressionCompletionEntry.Kind.input, "An input port of this node."),
                                               ("out", .output, "An output port of this node."),
                                               ("let", .input, "A name this expression gives a value.")]
        {
            guard let regex = try? NSRegularExpression(pattern: #"\b\#(keyword)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
            else { continue }

            let text = self.documentText as NSString
            for match in regex.matches(in: self.documentText, range: NSRange(location: 0, length: text.length))
            {
                guard match.numberOfRanges > 1 else { continue }
                let name = text.substring(with: match.range(at: 1))
                guard seen.insert(name).inserted else { continue }

                entries.append(MathExpressionCompletionEntry(label: name,
                                                             insertText: name,
                                                             documentation: documentation,
                                                             kind: kind,
                                                             priority: 600))
            }
        }

        return entries
    }

    // MARK: - Unused parts of the protocol

    public func tokens(for lineRange: Range<Int>) async throws -> [[(token: LanguageConfiguration.Token, range: NSRange)]]
    {
        []
    }

    public func info(at location: Int) async throws -> (view: any View, anchor: NSRange?)?
    {
        nil
    }

    public func capabilities() async throws -> (any View)?
    {
        Text("Local completions for Fabric Math Expression nodes.")
    }

    // MARK: - Text

    private func identifierRange(at location: Int) -> NSRange
    {
        let nsText = self.documentText as NSString
        var start = location
        var end = location

        while start > 0, self.isIdentifierCharacter(nsText.character(at: start - 1)) { start -= 1 }
        while end < nsText.length, self.isIdentifierCharacter(nsText.character(at: end)) { end += 1 }

        return NSRange(location: start, length: end - start)
    }

    private func isIdentifierCharacter(_ character: unichar) -> Bool
    {
        guard let scalar = UnicodeScalar(character) else { return false }
        return Self.identifierCharacters.contains(scalar)
    }
}
