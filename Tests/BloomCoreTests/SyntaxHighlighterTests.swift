import Foundation
import Testing
@testable import BloomCore

/// Tokenizes a line and checks the invariants every language has to satisfy: tokens in order,
/// none empty, none reaching past the line. `sourceLocation` is threaded through so a violation
/// is reported against the test that tokenized the line, not against this function.
private func checked(
    _ line: String,
    language: Language,
    state: inout LexState,
    sourceLocation: SourceLocation = #_sourceLocation
) -> [Token] {
    let tokens = SyntaxHighlighter.tokenize(line: line, language: language, carry: &state)
    var previousEnd = 0
    for token in tokens {
        #expect(token.range.lowerBound >= previousEnd, sourceLocation: sourceLocation)
        #expect(token.range.lowerBound >= 0, sourceLocation: sourceLocation)
        #expect(token.range.upperBound <= line.utf16.count, sourceLocation: sourceLocation)
        #expect(token.range.isEmpty == false, sourceLocation: sourceLocation)
        previousEnd = token.range.upperBound
    }
    return tokens
}

private func checked(
    _ line: String,
    language: Language,
    sourceLocation: SourceLocation = #_sourceLocation
) -> [Token] {
    var state = LexState()
    return checked(line, language: language, state: &state, sourceLocation: sourceLocation)
}

private func text(of token: Token, in line: String) -> String {
    let units = Array(line.utf16)
    return String(decoding: units[token.range], as: UTF16.self)
}

private func has(_ kind: TokenKind, text expected: String, in line: String, tokens: [Token]) -> Bool {
    tokens.contains { $0.kind == kind && text(of: $0, in: line) == expected }
}

@Suite("Syntax highlighter", .tags(.agentProtocol))
struct SyntaxHighlighterTests {
    @Test("detects languages from paths")
    func detectsPaths() {
        #expect(Language.detect(path: "app/Thing.php") == .php)
        #expect(Language.detect(path: "views/home.blade.php") == .blade)
        #expect(Language.detect(path: "Dockerfile") == .shell)
        #expect(Language.detect(path: ".env") == .shell)
        #expect(Language.detect(path: "Makefile") == .shell)
        #expect(Language.detect(path: ".zshrc") == .shell)
        #expect(Language.detect(path: "notes.unknown") == .plainText)
    }

    @Test("detects languages from fence tags")
    func detectsFences() {
        #expect(Language.detect(fenceInfo: "bash") == .shell)
        #expect(Language.detect(fenceInfo: "sh") == .shell)
        #expect(Language.detect(fenceInfo: "js") == .javascript)
        #expect(Language.detect(fenceInfo: "ts") == .typescript)
        #expect(Language.detect(fenceInfo: "php") == .php)
        #expect(Language.detect(fenceInfo: "") == .plainText)
    }

    @Test("highlights PHP declarations and comments")
    func phpDeclarations() {
        let lines = [
            "<?php",
            "/** A service. */",
            "#[Singleton]",
            "final class Greeter {",
            "    public readonly string $name;",
            "    public function greet(User $user, bool $loud = false): string {}",
            "}",
            "# final note",
        ]
        var state = LexState()
        let all = lines.map { checked($0, language: .php, state: &state) }
        #expect(has(.comment, text: "/** A service. */", in: lines[1], tokens: all[1]))
        #expect(has(.attribute, text: "#[", in: lines[2], tokens: all[2]))
        #expect(has(.keyword, text: "class", in: lines[3], tokens: all[3]))
        #expect(has(.type, text: "string", in: lines[4], tokens: all[4]))
        #expect(has(.variable, text: "$name", in: lines[4], tokens: all[4]))
        #expect(has(.comment, text: "# final note", in: lines[7], tokens: all[7]))
    }

    @Test("distinguishes PHP string interpolation")
    func phpStrings() {
        let doubleLine = #"echo "Hello $name";"#
        let singleLine = "echo 'Hello $name';"
        let doubleTokens = checked(doubleLine, language: .php)
        let singleTokens = checked(singleLine, language: .php)
        #expect(has(.variable, text: "$name", in: doubleLine, tokens: doubleTokens))
        #expect(singleTokens.contains(where: { $0.kind == .variable }) == false)
    }

    @Test("threads heredoc and nowdoc state")
    func phpDocumentStrings() {
        var state = LexState()
        _ = checked("$a = <<<EOT", language: .php, state: &state)
        let heredoc = "$value"
        let heredocTokens = checked(heredoc, language: .php, state: &state)
        _ = checked("EOT;", language: .php, state: &state)
        _ = checked("$b = <<<'TXT'", language: .php, state: &state)
        let nowdoc = "$value"
        let nowdocTokens = checked(nowdoc, language: .php, state: &state)
        _ = checked("TXT;", language: .php, state: &state)
        #expect(has(.variable, text: "$value", in: heredoc, tokens: heredocTokens))
        #expect(nowdocTokens == [Token(kind: .string, range: 0..<6)])
    }

    @Test("highlights Blade additions over HTML")
    func blade() {
        let directive = "@if ($ready)"
        let echo = "<p>{{ $name }}</p>"
        let comment = "{{-- hidden --}}"
        #expect(has(.attribute, text: "@if", in: directive, tokens: checked(directive, language: .blade)))
        #expect(has(.variable, text: "$name", in: echo, tokens: checked(echo, language: .blade)))
        #expect(has(.comment, text: comment, in: comment, tokens: checked(comment, language: .blade)))
    }

    @Test("highlights Swift strings and declarations")
    func swift() {
        let attribute = "@MainActor struct Runner {}"
        let identifier = "let `class` = 1"
        let interpolation = #"let greeting = "Hello \(name)""#
        let raw = ##"let raw = #"value \#(name)"#"##
        #expect(has(.attribute, text: "@MainActor", in: attribute, tokens: checked(attribute, language: .swift)))
        #expect(has(.variable, text: "`class`", in: identifier, tokens: checked(identifier, language: .swift)))
        #expect(checked(interpolation, language: .swift).contains { $0.kind == .variable })
        #expect(checked(raw, language: .swift).contains { $0.kind == .variable })
    }

    @Test("threads a Swift multiline string")
    func swiftMultilineString() {
        var state = LexState()
        let first = "let text = \"\"\"hello"
        let middle = "world"
        let last = "done\"\"\" + suffix"
        _ = checked(first, language: .swift, state: &state)
        let middleTokens = checked(middle, language: .swift, state: &state)
        let lastTokens = checked(last, language: .swift, state: &state)
        #expect(middleTokens == [Token(kind: .string, range: 0..<5)])
        #expect(has(.plain, text: "suffix", in: last, tokens: lastTokens))
    }

    @Test("highlights JavaScript and TypeScript constructs")
    func javascriptAndTypeScript() {
        let template = "const value = `hello ${name}`"
        let arrow = "const twice = (value: number) => value * 2"
        let regex = "const pattern = /a[b\\/]c+/gi"
        let division = "const ratio = total / count"
        #expect(checked(template, language: .javascript).contains { $0.kind == .variable })
        #expect(has(.operator, text: "=>", in: arrow, tokens: checked(arrow, language: .typescript)))
        #expect(checked(regex, language: .javascript).contains { $0.kind == .regex })
        #expect(checked(division, language: .javascript).contains(where: { $0.kind == .regex }) == false)
    }

    @Test("threads block comments across lines")
    func blockCommentCarry() {
        var state = LexState()
        let lines = ["let x = /* open", "middle one", "middle two", "close */ let y"]
        let results = lines.map { checked($0, language: .swift, state: &state) }
        #expect(results[1] == [Token(kind: .comment, range: 0..<10)])
        #expect(results[2] == [Token(kind: .comment, range: 0..<10)])
        #expect(results[3].first?.kind == .comment)
        #expect(results[3].contains { $0.kind == .keyword })
    }

    @Test("uses UTF-16 offsets")
    func utf16Offsets() {
        let line = "😀 café $name"
        let tokens = checked(line, language: .php)
        let variable = tokens.first { $0.kind == .variable }
        #expect(variable?.range == 8..<13)
        #expect(variable.map { text(of: $0, in: line) } == "$name")
    }

    @Test("handles empty whitespace and punctuation lines")
    func degenerateLines() {
        #expect(checked("", language: .swift).isEmpty)
        #expect(checked("   \t", language: .swift) == [Token(kind: .plain, range: 0..<4)])
        let punctuation = "()[]{}.,;:+-*/"
        let tokens = checked(punctuation, language: .swift)
        #expect(tokens.last?.range.upperBound == punctuation.utf16.count)
        _ = checked("\"unterminated", language: .swift)
        _ = checked("'unterminated", language: .shell)
    }

    @Test("finishes a very long line")
    func longLine() {
        let line = String(repeating: "a", count: 100_000)
        let tokens = checked(line, language: .swift)
        #expect(tokens == [Token(kind: .plain, range: 0..<100_000)])
    }
}
