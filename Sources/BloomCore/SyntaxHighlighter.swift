import Foundation

/// Semantic categories keep source rendering independent from any particular colour palette.
public enum TokenKind: String, Sendable, CaseIterable {
    case plain, keyword, type, string, number, comment, function, variable
    case attribute, `operator`, punctuation, regex, constant
}

/// UTF-16 ranges avoid repeated index conversion when a view applies highlighting attributes.
public struct Token: Sendable, Hashable {
    public var kind: TokenKind
    public var range: Range<Int>

    public init(kind: TokenKind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}

/// A compact language set lets callers select highlighting without loading parser runtimes.
public enum Language: String, Sendable, CaseIterable {
    case php, swift, javascript, typescript, python, ruby, go, rust, java, kotlin
    case css, html, json, yaml, toml, markdown, shell, sql, blade, vue, xml, plainText

    public static func detect(path: String) -> Language {
        let filename = (path as NSString).lastPathComponent.lowercased()

        if filename.hasSuffix(".blade.php") { return .blade }

        switch filename {
        case "dockerfile", "makefile", "justfile", "bashrc", ".bashrc", ".zshrc", ".profile":
            return .shell
        case let name where name == ".env" || name.hasPrefix(".env."):
            return .shell
        default:
            break
        }

        let extensionName = (filename as NSString).pathExtension
        return switch extensionName {
        case "php", "phtml": .php
        case "swift": .swift
        case "js", "jsx", "mjs", "cjs": .javascript
        case "ts", "tsx", "mts", "cts": .typescript
        case "py": .python
        case "rb": .ruby
        case "go": .go
        case "rs": .rust
        case "java": .java
        case "kt", "kts": .kotlin
        case "css", "scss", "sass", "less": .css
        case "html", "htm": .html
        case "json", "jsonc": .json
        case "yaml", "yml": .yaml
        case "toml": .toml
        case "md", "markdown": .markdown
        case "sh", "bash", "zsh", "fish": .shell
        case "sql": .sql
        case "vue": .vue
        case "xml", "svg": .xml
        default: .plainText
        }
    }

    public static func detect(fenceInfo: String) -> Language {
        let tag = fenceInfo
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first?
            .lowercased() ?? ""

        return switch tag {
        case "php": .php
        case "blade": .blade
        case "swift": .swift
        case "js", "javascript", "jsx", "node": .javascript
        case "ts", "typescript", "tsx": .typescript
        case "py", "python": .python
        case "rb", "ruby": .ruby
        case "go", "golang": .go
        case "rs", "rust": .rust
        case "java": .java
        case "kt", "kotlin": .kotlin
        case "css", "scss", "sass", "less": .css
        case "html": .html
        case "json", "jsonc": .json
        case "yaml", "yml": .yaml
        case "toml": .toml
        case "md", "markdown": .markdown
        case "sh", "shell", "bash", "zsh", "console": .shell
        case "sql": .sql
        case "vue": .vue
        case "xml": .xml
        default: .plainText
        }
    }
}

private enum MultilineString: Sendable, Hashable {
    case swiftTriple
    case template
}

/// Carry state makes independently rendered lines agree about constructs opened above them.
public struct LexState: Sendable, Hashable {
    fileprivate var blockCommentEnd: String?
    fileprivate var multilineString: MultilineString?
    fileprivate var heredocTag: String?
    fileprivate var heredocInterpolates = false

    public init() {}
}

/// A bounded hand-written scanner keeps highlighting cheap enough for lazy diff rows.
public enum SyntaxHighlighter {
    public static func tokenize(line: String, language: Language, carry: inout LexState) -> [Token] {
        var lexer = Lexer(line: line, language: language, state: carry)
        let tokens = lexer.run()
        carry = lexer.state
        assertTokens(tokens, length: line.utf16.count)
        return tokens
    }

    public static func tokenize(source: String, language: Language) -> [[Token]] {
        var state = LexState()
        return source.components(separatedBy: "\n").map {
            tokenize(line: $0, language: language, carry: &state)
        }
    }

    private static func assertTokens(_ tokens: [Token], length: Int) {
        var end = 0
        for token in tokens {
            assert(token.range.lowerBound >= end)
            assert(token.range.lowerBound >= 0 && token.range.upperBound <= length)
            assert(!token.range.isEmpty)
            end = token.range.upperBound
        }
    }
}

private struct Lexer {
    private let units: [UInt16]
    private let language: Language
    fileprivate var state: LexState
    private var cursor = 0
    private var tokens: [Token] = []

    init(line: String, language: Language, state: LexState) {
        units = Array(line.utf16)
        self.language = language
        self.state = state
    }

    mutating func run() -> [Token] {
        if scanCarriedConstruct() { return tokens }

        while cursor < units.count {
            let start = cursor

            if scanWhitespace()
                || scanComment()
                || scanLanguageSpecial()
                || scanString()
                || scanNumber()
                || scanIdentifier()
                || scanOperatorOrPunctuation() {
                continue
            }

            cursor += 1
            add(.plain, start, cursor)
        }

        return tokens
    }

    private mutating func scanCarriedConstruct() -> Bool {
        if let tag = state.heredocTag {
            let text = decode(0, units.count).trimmingCharacters(in: .whitespaces)
            let terminator = text == tag || text == "\(tag);"
            if terminator {
                add(.string, 0, units.count)
                state.heredocTag = nil
                state.heredocInterpolates = false
            } else if state.heredocInterpolates {
                scanInterpolatedBody(from: 0, to: units.count, style: .dollar)
            } else {
                add(.string, 0, units.count)
            }
            cursor = units.count
            return true
        }

        if let endText = state.blockCommentEnd {
            let end = ascii(endText)
            if let found = find(end, from: 0) {
                cursor = found + end.count
                add(.comment, 0, cursor)
                state.blockCommentEnd = nil
                return false
            }
            add(.comment, 0, units.count)
            cursor = units.count
            return true
        }

        if let multiline = state.multilineString {
            let delimiter = multiline == .swiftTriple ? ascii("\"\"\"") : ascii("`")
            if let found = find(delimiter, from: 0) {
                let end = found + delimiter.count
                scanInterpolatedBody(
                    from: 0,
                    to: end,
                    style: multiline == .template ? .bracedDollar : .swift
                )
                cursor = end
                state.multilineString = nil
                return false
            }
            scanInterpolatedBody(
                from: 0,
                to: units.count,
                style: multiline == .template ? .bracedDollar : .swift
            )
            cursor = units.count
            return true
        }

        return false
    }

    private mutating func scanWhitespace() -> Bool {
        guard isWhitespace(at: cursor) else { return false }
        let start = cursor
        while cursor < units.count, isWhitespace(at: cursor) { cursor += 1 }
        add(.plain, start, cursor)
        return true
    }

    private mutating func scanComment() -> Bool {
        let start = cursor

        if language == .blade, matches("{{--", at: cursor) {
            return scanBlockComment(start: start, openerLength: 4, end: "--}}")
        }
        if [.html, .xml, .vue, .blade].contains(language), matches("<!--", at: cursor) {
            return scanBlockComment(start: start, openerLength: 4, end: "-->")
        }
        if supportsSlashComments, matches("/*", at: cursor) {
            return scanBlockComment(start: start, openerLength: 2, end: "*/")
        }
        if supportsSlashComments, matches("//", at: cursor) {
            cursor = units.count
            add(.comment, start, cursor)
            return true
        }
        if hashStartsComment, unit(at: cursor) == 35 {
            if language == .php, unit(at: cursor + 1) == 91 { return false }
            cursor = units.count
            add(.comment, start, cursor)
            return true
        }
        if language == .sql, matches("--", at: cursor) {
            cursor = units.count
            add(.comment, start, cursor)
            return true
        }
        if language == .markdown, matches("[//]:", at: cursor) {
            cursor = units.count
            add(.comment, start, cursor)
            return true
        }
        return false
    }

    private mutating func scanBlockComment(start: Int, openerLength: Int, end: String) -> Bool {
        let endUnits = ascii(end)
        if let found = find(endUnits, from: cursor + openerLength) {
            cursor = found + endUnits.count
        } else {
            cursor = units.count
            state.blockCommentEnd = end
        }
        add(.comment, start, cursor)
        return true
    }

    private mutating func scanLanguageSpecial() -> Bool {
        let start = cursor

        if language == .php, matches("<?php", at: cursor) {
            cursor += 5
            add(.punctuation, start, cursor)
            return true
        }
        if language == .php, matches("<?=", at: cursor) {
            cursor += 3
            add(.punctuation, start, cursor)
            return true
        }
        if language == .php, matches("<<<", at: cursor) {
            return scanHeredoc()
        }
        if language == .php, matches("#[", at: cursor) {
            cursor += 2
            add(.attribute, start, cursor)
            return true
        }
        if language == .blade, unit(at: cursor) == 64, isIdentifierStart(at: cursor + 1) {
            cursor += 2
            while isIdentifierContinue(at: cursor) { cursor += 1 }
            add(.attribute, start, cursor)
            return true
        }
        if [.swift, .java, .kotlin].contains(language), unit(at: cursor) == 64,
           isIdentifierStart(at: cursor + 1) {
            cursor += 2
            while isIdentifierContinue(at: cursor) { cursor += 1 }
            add(.attribute, start, cursor)
            return true
        }
        if language == .swift, unit(at: cursor) == 96 {
            cursor += 1
            while cursor < units.count, unit(at: cursor) != 96 { cursor += 1 }
            if cursor < units.count { cursor += 1 }
            add(.variable, start, cursor)
            return true
        }
        if [.php, .blade, .shell].contains(language), unit(at: cursor) == 36 {
            return scanDollarVariable()
        }
        if language == .markdown, matches("```", at: cursor) {
            cursor = units.count
            add(.punctuation, start, cursor)
            return true
        }
        return false
    }

    private mutating func scanHeredoc() -> Bool {
        let start = cursor
        cursor += 3
        while isWhitespace(at: cursor) { cursor += 1 }
        var interpolates = true
        var quote: UInt16?
        if unit(at: cursor) == 39 || unit(at: cursor) == 34 {
            quote = unit(at: cursor)
            interpolates = quote == 34
            cursor += 1
        }
        let tagStart = cursor
        while isIdentifierContinue(at: cursor) { cursor += 1 }
        guard cursor > tagStart else {
            add(.operator, start, cursor)
            return true
        }
        let tag = decode(tagStart, cursor)
        if let quote, unit(at: cursor) == quote { cursor += 1 }
        state.heredocTag = tag
        state.heredocInterpolates = interpolates
        cursor = units.count
        add(.string, start, cursor)
        return true
    }

    private mutating func scanDollarVariable() -> Bool {
        let start = cursor
        cursor += 1
        if unit(at: cursor) == 123 {
            cursor += 1
            while cursor < units.count, unit(at: cursor) != 125 { cursor += 1 }
            if cursor < units.count { cursor += 1 }
        } else {
            while isIdentifierContinue(at: cursor) { cursor += 1 }
        }
        if cursor == start + 1, language == .shell, unit(at: cursor) == 40 {
            var depth = 0
            repeat {
                if unit(at: cursor) == 40 { depth += 1 }
                if unit(at: cursor) == 41 { depth -= 1 }
                cursor += 1
            } while cursor < units.count && depth > 0
        }
        add(.variable, start, cursor)
        return true
    }

    private mutating func scanString() -> Bool {
        let start = cursor

        if language == .swift, matches("\"\"\"", at: cursor) {
            cursor += 3
            if let found = find(ascii("\"\"\""), from: cursor) {
                cursor = found + 3
                scanInterpolatedBody(from: start, to: cursor, style: .swift)
            } else {
                cursor = units.count
                state.multilineString = .swiftTriple
                scanInterpolatedBody(from: start, to: cursor, style: .swift)
            }
            return true
        }
        if language == .swift, unit(at: cursor) == 35 {
            var hashes = 0
            while unit(at: cursor + hashes) == 35 { hashes += 1 }
            if unit(at: cursor + hashes) == 34 {
                cursor += hashes + 1
                let closing = [UInt16](repeating: 35, count: hashes)
                scanUntilQuote(quote: 34, suffix: closing, interpolation: .swiftRaw(hashes))
                return true
            }
        }
        if [.javascript, .typescript].contains(language), unit(at: cursor) == 96 {
            cursor += 1
            if let found = findUnescaped(96, from: cursor) {
                cursor = found + 1
                scanInterpolatedBody(from: start, to: cursor, style: .bracedDollar)
            } else {
                cursor = units.count
                state.multilineString = .template
                scanInterpolatedBody(from: start, to: cursor, style: .bracedDollar)
            }
            return true
        }
        let quote = unit(at: cursor)
        guard quote == 34 || quote == 39 else { return false }
        cursor += 1
        let interpolation: InterpolationStyle
        if quote == 39 {
            interpolation = .none
        } else if language == .php || language == .shell {
            interpolation = .dollar
        } else if language == .swift {
            interpolation = .swift
        } else {
            interpolation = .none
        }
        scanUntilQuote(quote: quote, suffix: [], interpolation: interpolation)
        return true
    }

    private mutating func scanUntilQuote(
        quote: UInt16,
        suffix: [UInt16],
        interpolation: InterpolationStyle
    ) {
        let start = cursor - 1 - suffix.count
        while cursor < units.count {
            if unit(at: cursor) == 92 {
                cursor = min(cursor + 2, units.count)
                continue
            }
            if unit(at: cursor) == quote, matches(suffix, at: cursor + 1) {
                cursor += 1 + suffix.count
                break
            }
            cursor += 1
        }
        scanInterpolatedBody(from: start, to: cursor, style: interpolation)
    }

    private mutating func scanInterpolatedBody(from start: Int, to end: Int, style: InterpolationStyle) {
        var part = start
        var index = start
        while index < end {
            var variableEnd: Int?
            switch style {
            case .dollar:
                if unit(at: index) == 36 {
                    variableEnd = dollarEnd(at: index, limit: end)
                }
            case .bracedDollar:
                if matches("${", at: index) {
                    var candidate = index + 2
                    while candidate < end, unit(at: candidate) != 125 { candidate += 1 }
                    variableEnd = candidate < end ? candidate + 1 : end
                }
            case .swift:
                if matches("\\(", at: index) {
                    variableEnd = closingParenthesis(from: index + 2, limit: end)
                }
            case let .swiftRaw(hashes):
                let marker = "\\" + String(repeating: "#", count: hashes) + "("
                if matches(marker, at: index) {
                    variableEnd = closingParenthesis(from: index + marker.utf16.count, limit: end)
                }
            case .none:
                break
            }

            if let variableEnd, variableEnd > index {
                add(.string, part, index)
                add(.variable, index, variableEnd)
                index = variableEnd
                part = index
            } else {
                index += 1
            }
        }
        add(.string, part, end)
    }

    private func dollarEnd(at start: Int, limit: Int) -> Int? {
        if unit(at: start + 1) == 123 {
            var end = start + 2
            while end < limit, unit(at: end) != 125 { end += 1 }
            return end < limit ? end + 1 : limit
        }
        if language == .shell, unit(at: start + 1) == 40 {
            return closingParenthesis(from: start + 2, limit: limit)
        }
        guard isIdentifierStart(at: start + 1) else { return nil }
        var end = start + 2
        while end < limit, isIdentifierContinue(at: end) { end += 1 }
        return end
    }

    private func closingParenthesis(from start: Int, limit: Int) -> Int {
        var index = start
        var depth = 1
        while index < limit {
            if unit(at: index) == 40 { depth += 1 }
            if unit(at: index) == 41 {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return limit
    }

    private mutating func scanNumber() -> Bool {
        guard isDigit(at: cursor) else { return false }
        let start = cursor
        cursor += 1
        while cursor < units.count {
            let value = unit(at: cursor)
            if isDigit(at: cursor) || value == 46 || value == 95
                || (value >= 65 && value <= 70) || (value >= 97 && value <= 102)
                || value == 120 || value == 98 {
                cursor += 1
            } else {
                break
            }
        }
        add(.number, start, cursor)
        return true
    }

    private mutating func scanIdentifier() -> Bool {
        guard isIdentifierStart(at: cursor) else { return false }
        let start = cursor
        cursor += 1
        while isIdentifierContinue(at: cursor) { cursor += 1 }
        let word = decode(start, cursor)
        let lower = word.lowercased()
        let kind: TokenKind

        if keywords.contains(lower) {
            kind = .keyword
        } else if constants.contains(lower) {
            kind = .constant
        } else if types.contains(lower) || word.first?.isUppercase == true {
            kind = .type
        } else if nextNonWhitespace(after: cursor) == 40 {
            kind = .function
        } else if language == .php, nextNonWhitespace(after: cursor) == 58,
                  unit(at: nextNonWhitespaceIndex(after: cursor) + 1) != 58 {
            kind = .variable
        } else if isHTMLLike, isInsideHTMLTag(at: start) {
            kind = isHTMLTagName(at: start) ? .type : .attribute
        } else if [.yaml, .toml, .json, .css].contains(language),
                  nextNonWhitespace(after: cursor) == 58 || nextNonWhitespace(after: cursor) == 61 {
            kind = .attribute
        } else {
            kind = .plain
        }
        add(kind, start, cursor)
        return true
    }

    private mutating func scanOperatorOrPunctuation() -> Bool {
        let start = cursor
        if [.javascript, .typescript].contains(language), unit(at: cursor) == 47,
           shouldStartRegex(), let end = regexEnd(from: cursor) {
            cursor = end
            add(.regex, start, cursor)
            return true
        }

        for text in ["<=>", "===", "!==", "...", "??=", "->", "::", "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "**", "<<", ">>", "{{", "}}", "{!!", "!!}"] {
            if matches(text, at: cursor) {
                cursor += text.utf16.count
                add(.operator, start, cursor)
                return true
            }
        }

        let value = unit(at: cursor)
        if asciiOperators.contains(value) {
            cursor += 1
            add(.operator, start, cursor)
            return true
        }
        if asciiPunctuation.contains(value) {
            cursor += 1
            add(.punctuation, start, cursor)
            return true
        }
        return false
    }

    /// A slash starts a regex after expression-leading punctuation or selected keywords.
    /// Elsewhere it is treated as division. This intentionally favours readable diffs over parsing.
    private func shouldStartRegex() -> Bool {
        var index = cursor - 1
        while index >= 0, isWhitespace(at: index) { index -= 1 }
        if index < 0 { return true }
        if ascii("=(:,![{;?").contains(unit(at: index)) { return true }
        let prefix = decode(0, index + 1)
        let lastWord = prefix.split { !$0.isLetter }.last?.lowercased()
        return ["return", "case", "throw", "typeof", "delete", "void", "yield"].contains(lastWord)
    }

    private func regexEnd(from start: Int) -> Int? {
        var index = start + 1
        var inClass = false
        while index < units.count {
            let value = unit(at: index)
            if value == 92 {
                index = min(index + 2, units.count)
                continue
            }
            if value == 91 { inClass = true }
            if value == 93 { inClass = false }
            if value == 47, !inClass {
                index += 1
                while isASCIIAlpha(at: index) { index += 1 }
                return index
            }
            index += 1
        }
        return nil
    }

    private var supportsSlashComments: Bool {
        ![.python, .ruby, .yaml, .toml, .shell, .sql, .markdown, .plainText].contains(language)
    }

    private var hashStartsComment: Bool {
        [.php, .python, .ruby, .yaml, .toml, .shell].contains(language)
    }

    private var isHTMLLike: Bool {
        [.html, .xml, .vue, .blade].contains(language)
    }

    private func isInsideHTMLTag(at index: Int) -> Bool {
        var position = index - 1
        while position >= 0 {
            if unit(at: position) == 62 { return false }
            if unit(at: position) == 60 { return true }
            position -= 1
        }
        return false
    }

    private func isHTMLTagName(at index: Int) -> Bool {
        var position = index - 1
        while position >= 0, isWhitespace(at: position) { position -= 1 }
        if unit(at: position) == 60 { return true }
        return unit(at: position) == 47 && unit(at: position - 1) == 60
    }

    private var keywords: Set<String> {
        switch language {
        case .php, .blade:
            ["abstract", "as", "break", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "enum", "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include", "instanceof", "interface", "match", "namespace", "new", "private", "protected", "public", "readonly", "require", "return", "static", "throw", "trait", "try", "use", "while", "yield"]
        case .swift:
            ["actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "fallthrough", "for", "func", "guard", "if", "import", "in", "inout", "is", "let", "nonisolated", "private", "protocol", "public", "repeat", "return", "some", "static", "struct", "switch", "throw", "throws", "try", "var", "where", "while"]
        case .javascript, .typescript:
            ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "interface", "let", "new", "of", "return", "static", "switch", "throw", "try", "typeof", "var", "void", "while", "with", "yield"]
        case .sql:
            ["alter", "and", "as", "asc", "begin", "between", "by", "case", "create", "delete", "desc", "distinct", "drop", "else", "end", "exists", "from", "group", "having", "in", "index", "inner", "insert", "into", "is", "join", "left", "like", "limit", "not", "null", "on", "or", "order", "outer", "right", "select", "set", "table", "then", "union", "update", "values", "when", "where"]
        case .python:
            ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"]
        case .ruby:
            ["begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end", "ensure", "for", "if", "in", "module", "next", "redo", "rescue", "retry", "return", "self", "super", "then", "unless", "until", "when", "while", "yield"]
        default:
            ["break", "case", "catch", "class", "const", "continue", "default", "else", "enum", "extends", "false", "final", "for", "fun", "func", "if", "import", "interface", "let", "new", "package", "private", "protected", "public", "return", "static", "struct", "switch", "throw", "true", "try", "var", "void", "while"]
        }
    }

    private var types: Set<String> {
        ["array", "bool", "boolean", "char", "double", "float", "int", "integer", "mixed", "never", "number", "object", "self", "string", "void", "any", "some"]
    }

    private var constants: Set<String> {
        ["true", "false", "null", "nil", "none", "undefined", "nan", "inf"]
    }

    private mutating func add(_ kind: TokenKind, _ start: Int, _ end: Int) {
        guard start < end else { return }
        if let last = tokens.last, kind != .plain, last.kind == kind, last.range.upperBound == start {
            tokens[tokens.count - 1].range = last.range.lowerBound..<end
        } else {
            tokens.append(Token(kind: kind, range: start..<end))
        }
    }

    private func unit(at index: Int) -> UInt16 {
        guard index >= 0, index < units.count else { return 0 }
        return units[index]
    }

    private func matches(_ text: String, at index: Int) -> Bool {
        matches(ascii(text), at: index)
    }

    private func matches(_ needle: [UInt16], at index: Int) -> Bool {
        guard index >= 0, index + needle.count <= units.count else { return false }
        for offset in needle.indices where units[index + offset] != needle[offset] { return false }
        return true
    }

    private func find(_ needle: [UInt16], from start: Int) -> Int? {
        guard !needle.isEmpty, start <= units.count - needle.count else { return nil }
        var index = max(0, start)
        while index + needle.count <= units.count {
            if matches(needle, at: index) { return index }
            index += 1
        }
        return nil
    }

    private func findUnescaped(_ needle: UInt16, from start: Int) -> Int? {
        var index = start
        while index < units.count {
            if unit(at: index) == 92 {
                index = min(index + 2, units.count)
            } else if unit(at: index) == needle {
                return index
            } else {
                index += 1
            }
        }
        return nil
    }

    private func decode(_ start: Int, _ end: Int) -> String {
        String(decoding: units[start..<end], as: UTF16.self)
    }

    private func isWhitespace(at index: Int) -> Bool {
        let value = unit(at: index)
        return value == 9 || value == 10 || value == 13 || value == 32
    }

    private func isDigit(at index: Int) -> Bool {
        let value = unit(at: index)
        return value >= 48 && value <= 57
    }

    private func isASCIIAlpha(at index: Int) -> Bool {
        let value = unit(at: index)
        return (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }

    private func isIdentifierStart(at index: Int) -> Bool {
        let value = unit(at: index)
        return isASCIIAlpha(at: index) || value == 95 || value >= 128
    }

    private func isIdentifierContinue(at index: Int) -> Bool {
        isIdentifierStart(at: index) || isDigit(at: index)
    }

    private func nextNonWhitespaceIndex(after index: Int) -> Int {
        var result = index
        while result < units.count, isWhitespace(at: result) { result += 1 }
        return result
    }

    private func nextNonWhitespace(after index: Int) -> UInt16 {
        unit(at: nextNonWhitespaceIndex(after: index))
    }
}

private enum InterpolationStyle {
    case none
    case dollar
    case bracedDollar
    case swift
    case swiftRaw(Int)
}

private let asciiOperators = Set(ascii("+-*/%=!<>?&|^~"))
private let asciiPunctuation = Set(ascii("()[]{}.,;:@#\\"))

private func ascii(_ string: String) -> [UInt16] {
    Array(string.utf16)
}
