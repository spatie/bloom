import Foundation
import BloomCore

/// The alignment declared by a table separator row is retained so presentation stays outside parsing.
public enum TableAlignment: Sendable, Hashable {
    case leading
    case center
    case trailing
}

/// A small semantic inline tree preserves agent output that AttributedString alone cannot safely parse.
public indirect enum MarkdownInline: Sendable, Hashable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(text: [MarkdownInline], url: String)
    case lineBreak
}

/// Transcript markdown is represented as blocks so streaming code and structural prose are never dropped.
public indirect enum MarkdownBlock: Identifiable, Sendable, Hashable {
    case paragraph(inline: [MarkdownInline])
    case heading(level: Int, inline: [MarkdownInline])
    case codeBlock(code: String, language: Language, info: String)
    case bulletList(items: [[MarkdownBlock]], tight: Bool)
    case numberedList(start: Int, items: [[MarkdownBlock]], tight: Bool)
    case taskList(items: [(checked: Bool, inline: [MarkdownInline])])
    case blockQuote(blocks: [MarkdownBlock])
    case table(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]], alignments: [TableAlignment])
    case thematicBreak

    public var id: Int {
        var hasher = Hasher()
        hash(into: &hasher)
        return hasher.finalize()
    }

    public static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        switch (lhs, rhs) {
        case let (.paragraph(a), .paragraph(b)):
            a == b
        case let (.heading(al, ai), .heading(bl, bi)):
            al == bl && ai == bi
        case let (.codeBlock(ac, al, ai), .codeBlock(bc, bl, bi)):
            ac == bc && al == bl && ai == bi
        case let (.bulletList(ai, at), .bulletList(bi, bt)):
            ai == bi && at == bt
        case let (.numberedList(as_, ai, at), .numberedList(bs, bi, bt)):
            as_ == bs && ai == bi && at == bt
        case let (.taskList(a), .taskList(b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.checked == $1.checked && $0.inline == $1.inline }
        case let (.blockQuote(a), .blockQuote(b)):
            a == b
        case let (.table(ah, ar, aa), .table(bh, br, ba)):
            ah == bh && ar == br && aa == ba
        case (.thematicBreak, .thematicBreak):
            true
        default:
            false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .paragraph(inline):
            hasher.combine(0); hasher.combine(inline)
        case let .heading(level, inline):
            hasher.combine(1); hasher.combine(level); hasher.combine(inline)
        case let .codeBlock(code, language, info):
            hasher.combine(2); hasher.combine(code); hasher.combine(language); hasher.combine(info)
        case let .bulletList(items, tight):
            hasher.combine(3); hasher.combine(items); hasher.combine(tight)
        case let .numberedList(start, items, tight):
            hasher.combine(4); hasher.combine(start); hasher.combine(items); hasher.combine(tight)
        case let .taskList(items):
            hasher.combine(5)
            for item in items { hasher.combine(item.checked); hasher.combine(item.inline) }
        case let .blockQuote(blocks):
            hasher.combine(6); hasher.combine(blocks)
        case let .table(headers, rows, alignments):
            hasher.combine(7); hasher.combine(headers); hasher.combine(rows); hasher.combine(alignments)
        case .thematicBreak:
            hasher.combine(8)
        }
    }
}

/// A bounded hand-written parser keeps partial, rapidly changing transcript text cheap and deterministic.
public enum MarkdownParser: Sendable {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var parser = BlockParser(lines: normalized.components(separatedBy: "\n"), allowIndentedCode: true)
        return parser.parse()
    }
}

private struct ListMarker {
    var ordered: Bool
    var number: Int
    var indent: Int
    var contentOffset: Int
    var content: String
}

private struct BlockParser {
    let lines: [String]
    let allowIndentedCode: Bool
    var index = 0

    mutating func parse() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        while index < lines.count {
            let previous = index
            if isBlank(lines[index]) {
                index += 1
            } else if let block = parseFence() {
                blocks.append(block)
            } else if let block = parseATXHeading() {
                blocks.append(block)
            } else if let block = parseQuote() {
                blocks.append(block)
            } else if let block = parseList() {
                blocks.append(block)
            } else if let block = parseIndentedCode() {
                blocks.append(block)
            } else if isThematicBreak(lines[index]) {
                blocks.append(.thematicBreak)
                index += 1
            } else if let block = parseTable() {
                blocks.append(block)
            } else {
                blocks.append(parseParagraphOrSetext())
            }
            if index <= previous { index = previous + 1 }
        }
        return blocks
    }

    private mutating func parseFence() -> MarkdownBlock? {
        guard let opening = fence(in: lines[index], closing: false) else { return nil }
        index += 1
        var codeLines: [String] = []
        while index < lines.count {
            if let candidate = fence(in: lines[index], closing: true),
               candidate.character == opening.character,
               candidate.count >= opening.count {
                index += 1
                break
            }
            codeLines.append(lines[index])
            index += 1
        }
        let info = opening.info.trimmingCharacters(in: .whitespaces)
        let tag = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        return .codeBlock(code: codeLines.joined(separator: "\n"), language: Language.detect(fenceInfo: tag), info: info)
    }

    private mutating func parseATXHeading() -> MarkdownBlock? {
        let line = trimUpToThreeSpaces(lines[index])
        let count = line.prefix(while: { $0 == "#" }).count
        guard count > 0, count <= 6 else { return nil }
        let markerEnd = line.index(line.startIndex, offsetBy: count)
        guard markerEnd == line.endIndex || line[markerEnd].isWhitespace else { return nil }
        var content = String(line[markerEnd...]).trimmingCharacters(in: .whitespaces)
        while content.last == "#" { content.removeLast() }
        content = content.trimmingCharacters(in: .whitespaces)
        index += 1
        return .heading(level: count, inline: InlineParser.parse(content))
    }

    private mutating func parseQuote() -> MarkdownBlock? {
        guard quoteContent(lines[index]) != nil else { return nil }
        var quoted: [String] = []
        while index < lines.count {
            if let content = quoteContent(lines[index]) {
                quoted.append(content)
                index += 1
            } else if !isBlank(lines[index]) && !startsBlock(lines[index], at: index) {
                quoted.append(lines[index])
                index += 1
            } else {
                break
            }
        }
        var nested = BlockParser(lines: quoted, allowIndentedCode: true)
        return .blockQuote(blocks: nested.parse())
    }

    private mutating func parseList() -> MarkdownBlock? {
        guard let first = listMarker(lines[index]) else { return nil }
        let ordered = first.ordered
        let baseIndent = first.indent
        let start = first.number
        var items: [[MarkdownBlock]] = []
        var tasks: [(checked: Bool, inline: [MarkdownInline])?] = []
        var tight = true

        while index < lines.count {
            guard let marker = listMarker(lines[index]), marker.ordered == ordered, marker.indent == baseIndent else { break }
            index += 1
            var itemLines = [marker.content]
            var separated = false
            // A blank line only spreads a list out when something follows it: more of the same
            // item, or another item. Counting the blank line that simply ends the last item made
            // every list loose, because that is how every list in a document ends, and the tight
            // case the renderer draws was reachable only at the very end of a message.
            var blankPending = false

            while index < lines.count {
                if isBlank(lines[index]) {
                    blankPending = true
                    itemLines.append("")
                    index += 1
                    if index >= lines.count { break }
                    continue
                }
                if let next = listMarker(lines[index]), next.indent == baseIndent {
                    break
                }
                let indentation = leadingSpaces(lines[index])
                guard indentation > baseIndent else { break }
                let remove = min(indentation, marker.contentOffset)
                itemLines.append(dropLeadingColumns(lines[index], remove))
                if blankPending {
                    separated = true
                    blankPending = false
                }
                index += 1
            }

            if blankPending, index < lines.count, let next = listMarker(lines[index]),
               next.ordered == ordered, next.indent == baseIndent {
                separated = true
            }

            while itemLines.last.map(isBlank) == true { itemLines.removeLast() }
            tight = tight && !separated
            let task = taskContent(itemLines)
            tasks.append(task)
            var nested = BlockParser(lines: itemLines, allowIndentedCode: false)
            items.append(nested.parse())
        }

        if !ordered, tasks.count == items.count, tasks.allSatisfy({ $0 != nil }) {
            return .taskList(items: tasks.compactMap { $0 })
        }
        return ordered ? .numberedList(start: start, items: items, tight: tight) : .bulletList(items: items, tight: tight)
    }

    private mutating func parseIndentedCode() -> MarkdownBlock? {
        guard allowIndentedCode, leadingSpaces(lines[index]) >= 4 else { return nil }
        var code: [String] = []
        while index < lines.count {
            if isBlank(lines[index]) {
                code.append("")
                index += 1
            } else if leadingSpaces(lines[index]) >= 4 {
                code.append(dropLeadingColumns(lines[index], 4))
                index += 1
            } else {
                break
            }
        }
        while code.last == "" { code.removeLast() }
        return .codeBlock(code: code.joined(separator: "\n"), language: .plainText, info: "")
    }

    private mutating func parseTable() -> MarkdownBlock? {
        guard index + 1 < lines.count,
              lines[index].contains("|"),
              let alignments = tableAlignments(lines[index + 1]) else { return nil }
        let headerCells = tableCells(lines[index])
        guard !headerCells.isEmpty, headerCells.count == alignments.count else { return nil }
        index += 2
        var rows: [[[MarkdownInline]]] = []
        while index < lines.count, lines[index].contains("|"), !isBlank(lines[index]) {
            var cells = tableCells(lines[index])
            if cells.count < alignments.count { cells += Array(repeating: "", count: alignments.count - cells.count) }
            rows.append(cells.prefix(alignments.count).map(InlineParser.parse))
            index += 1
        }
        return .table(headers: headerCells.map(InlineParser.parse), rows: rows, alignments: alignments)
    }

    private mutating func parseParagraphOrSetext() -> MarkdownBlock {
        if index + 1 < lines.count, let level = setextLevel(lines[index + 1]), !isBlank(lines[index]) {
            let content = lines[index].trimmingCharacters(in: .whitespaces)
            index += 2
            return .heading(level: level, inline: InlineParser.parse(content))
        }

        var paragraph: [String] = []
        while index < lines.count, !isBlank(lines[index]) {
            if !paragraph.isEmpty && startsBlock(lines[index], at: index) { break }
            if !paragraph.isEmpty && index + 1 < lines.count && tableAlignments(lines[index + 1]) != nil { break }
            paragraph.append(lines[index])
            index += 1
        }
        return .paragraph(inline: InlineParser.parseLines(paragraph))
    }

    private func startsBlock(_ line: String, at position: Int) -> Bool {
        fence(in: line, closing: false) != nil
            || atxLevel(line) != nil
            || quoteContent(line) != nil
            || listMarker(line) != nil
            || isThematicBreak(line)
            || (allowIndentedCode && leadingSpaces(line) >= 4)
            || (position + 1 < lines.count && line.contains("|") && tableAlignments(lines[position + 1]) != nil)
    }
}

private struct Fence {
    var character: Character
    var count: Int
    var info: String
}

private func fence(in source: String, closing: Bool) -> Fence? {
    let line = trimUpToThreeSpaces(source)
    guard let first = line.first, first == "`" || first == "~" else { return nil }
    var count = 0
    var cursor = line.startIndex
    while cursor < line.endIndex, line[cursor] == first {
        count += 1
        cursor = line.index(after: cursor)
    }
    guard count >= 3 else { return nil }
    let remainder = String(line[cursor...])
    if closing && !remainder.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
    if first == "`" && remainder.contains("`") { return nil }
    return Fence(character: first, count: count, info: remainder)
}

private func atxLevel(_ source: String) -> Int? {
    let line = trimUpToThreeSpaces(source)
    let count = line.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(count) else { return nil }
    let end = line.index(line.startIndex, offsetBy: count)
    return end == line.endIndex || line[end].isWhitespace ? count : nil
}

private func setextLevel(_ source: String) -> Int? {
    let trimmed = source.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 1 else { return nil }
    if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
    if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
    return nil
}

private func isThematicBreak(_ source: String) -> Bool {
    let compact = trimUpToThreeSpaces(source).filter { !$0.isWhitespace }
    guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
    return compact.allSatisfy { $0 == first }
}

private func quoteContent(_ source: String) -> String? {
    let line = trimUpToThreeSpaces(source)
    guard line.first == ">" else { return nil }
    var content = line.dropFirst()
    if content.first == " " { content = content.dropFirst() }
    return String(content)
}

private func listMarker(_ source: String) -> ListMarker? {
    let indent = leadingSpaces(source)
    guard indent <= 3 || indent > 0 else { return nil }
    let line = dropLeadingColumns(source, indent)
    guard !line.isEmpty else { return nil }
    if let first = line.first, "-*+".contains(first) {
        let after = line.dropFirst()
        guard after.first?.isWhitespace == true else { return nil }
        let spaces = after.prefix(while: { $0.isWhitespace }).count
        return ListMarker(ordered: false, number: 1, indent: indent, contentOffset: indent + 1 + max(1, spaces), content: String(after.dropFirst(spaces)))
    }
    let digits = line.prefix(while: { $0.isNumber })
    guard !digits.isEmpty, digits.count <= 9 else { return nil }
    let markerIndex = line.index(line.startIndex, offsetBy: digits.count)
    guard markerIndex < line.endIndex, line[markerIndex] == "." || line[markerIndex] == ")" else { return nil }
    let afterMarker = line.index(after: markerIndex)
    guard afterMarker < line.endIndex, line[afterMarker].isWhitespace else { return nil }
    let remainder = line[afterMarker...]
    let spaces = remainder.prefix(while: { $0.isWhitespace }).count
    return ListMarker(ordered: true, number: Int(digits) ?? 1, indent: indent, contentOffset: indent + digits.count + 1 + max(1, spaces), content: String(remainder.dropFirst(spaces)))
}

private func taskContent(_ lines: [String]) -> (checked: Bool, inline: [MarkdownInline])? {
    guard let first = lines.first, first.count >= 3, first.first == "[" else { return nil }
    let chars = Array(first.prefix(3))
    guard chars[2] == "]", chars[1] == " " || chars[1] == "x" || chars[1] == "X" else { return nil }
    var content = String(first.dropFirst(3))
    if content.first == " " { content.removeFirst() }
    if lines.count > 1 { content += "\n" + lines.dropFirst().joined(separator: "\n") }
    return (chars[1] != " ", InlineParser.parse(content))
}

private func tableAlignments(_ source: String) -> [TableAlignment]? {
    let cells = tableCells(source)
    guard !cells.isEmpty else { return nil }
    var result: [TableAlignment] = []
    for cell in cells {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let leading = trimmed.hasPrefix(":")
        let trailing = trimmed.hasSuffix(":")
        let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard core.count >= 3, core.allSatisfy({ $0 == "-" }) else { return nil }
        result.append(leading && trailing ? .center : (trailing ? .trailing : .leading))
    }
    return result
}

private func tableCells(_ source: String) -> [String] {
    var line = source.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("|") { line.removeFirst() }
    if line.hasSuffix("|") && !line.hasSuffix("\\|") { line.removeLast() }
    var cells: [String] = []
    var current = ""
    var escaped = false
    for character in line {
        if escaped {
            current.append(character)
            escaped = false
        } else if character == "\\" {
            escaped = true
            current.append(character)
        } else if character == "|" {
            cells.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        } else {
            current.append(character)
        }
    }
    if escaped { current.append("\\") }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    return cells
}

private enum InlineParser {
    static func parseLines(_ lines: [String]) -> [MarkdownInline] {
        var output: [MarkdownInline] = []
        for (offset, raw) in lines.enumerated() {
            var line = raw
            var hardBreak = false
            if line.hasSuffix("\\") {
                line.removeLast()
                hardBreak = true
            } else if line.hasSuffix("  ") {
                while line.last == " " { line.removeLast() }
                hardBreak = true
            }
            output += parse(line)
            if offset < lines.count - 1 { output.append(hardBreak ? .lineBreak : .text(" ")) }
        }
        return coalesced(output)
    }

    static func parse(_ source: String) -> [MarkdownInline] {
        var scanner = Scanner(source)
        return coalesced(scanner.run())
    }

    private static func coalesced(_ input: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for value in input {
            if case let .text(text) = value, case let .text(previous)? = result.last {
                result[result.count - 1] = .text(previous + text)
            } else {
                result.append(value)
            }
        }
        return result
    }

    private struct Scanner {
        let source: String
        var cursor: String.Index

        init(_ source: String) {
            self.source = source
            cursor = source.startIndex
        }

        mutating func run() -> [MarkdownInline] {
            var result: [MarkdownInline] = []
            while cursor < source.endIndex {
                let previous = cursor
                if consumeEscape(into: &result)
                    || consumeCode(into: &result)
                    || consumeLink(into: &result)
                    || consumeAutolink(into: &result)
                    || consumeDelimited("**", make: MarkdownInline.strong, into: &result)
                    || consumeDelimited("__", make: MarkdownInline.strong, into: &result)
                    || consumeDelimited("~~", make: MarkdownInline.strikethrough, into: &result)
                    || consumeDelimited("*", make: MarkdownInline.emphasis, into: &result)
                    || consumeDelimited("_", make: MarkdownInline.emphasis, into: &result)
                    || consumeBareURL(into: &result) {
                } else {
                    result.append(.text(String(source[cursor])))
                    cursor = source.index(after: cursor)
                }
                if cursor <= previous { cursor = source.index(after: previous) }
            }
            return result
        }

        mutating func consumeEscape(into result: inout [MarkdownInline]) -> Bool {
            guard source[cursor] == "\\" else { return false }
            let next = source.index(after: cursor)
            guard next < source.endIndex, source[next].isPunctuation else { return false }
            result.append(.text(String(source[next])))
            cursor = source.index(after: next)
            return true
        }

        mutating func consumeCode(into result: inout [MarkdownInline]) -> Bool {
            guard source[cursor] == "`" else { return false }
            let count = source[cursor...].prefix(while: { $0 == "`" }).count
            let marker = String(repeating: "`", count: count)
            let contentStart = source.index(cursor, offsetBy: count)
            guard let close = source.range(of: marker, range: contentStart..<source.endIndex) else { return false }
            var content = String(source[contentStart..<close.lowerBound]).replacingOccurrences(of: "\n", with: " ")
            if content.hasPrefix(" "), content.hasSuffix(" "), content.trimmingCharacters(in: .whitespaces).isEmpty == false {
                content.removeFirst(); content.removeLast()
            }
            result.append(.code(content))
            cursor = close.upperBound
            return true
        }

        mutating func consumeLink(into result: inout [MarkdownInline]) -> Bool {
            guard source[cursor] == "[", let closeText = unescaped("]", from: source.index(after: cursor)) else { return false }
            let openURL = source.index(after: closeText)
            guard openURL < source.endIndex, source[openURL] == "(", let closeURL = unescaped(")", from: source.index(after: openURL)) else { return false }
            let text = String(source[source.index(after: cursor)..<closeText])
            let url = String(source[source.index(after: openURL)..<closeURL]).trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { return false }
            result.append(.link(text: InlineParser.parse(text), url: url))
            cursor = source.index(after: closeURL)
            return true
        }

        mutating func consumeAutolink(into result: inout [MarkdownInline]) -> Bool {
            guard source[cursor] == "<", let close = source[cursor...].firstIndex(of: ">") else { return false }
            let start = source.index(after: cursor)
            let value = String(source[start..<close])
            guard value.hasPrefix("https://") || value.hasPrefix("http://") else { return false }
            result.append(.link(text: [.text(value)], url: value))
            cursor = source.index(after: close)
            return true
        }

        mutating func consumeDelimited(_ marker: String, make: ([MarkdownInline]) -> MarkdownInline, into result: inout [MarkdownInline]) -> Bool {
            guard source[cursor...].hasPrefix(marker) else { return false }
            let contentStart = source.index(cursor, offsetBy: marker.count)
            guard contentStart < source.endIndex, let close = source.range(of: marker, range: contentStart..<source.endIndex)?.lowerBound, close > contentStart else { return false }
            result.append(make(InlineParser.parse(String(source[contentStart..<close]))))
            cursor = source.index(close, offsetBy: marker.count)
            return true
        }

        mutating func consumeBareURL(into result: inout [MarkdownInline]) -> Bool {
            let remainder = source[cursor...]
            guard remainder.hasPrefix("https://") || remainder.hasPrefix("http://") else { return false }
            var end = cursor
            while end < source.endIndex, !source[end].isWhitespace, source[end] != "<", source[end] != ">" { end = source.index(after: end) }
            var urlEnd = end
            while urlEnd > cursor, ".,;:!?".contains(source[source.index(before: urlEnd)]) { urlEnd = source.index(before: urlEnd) }
            guard urlEnd > cursor else { return false }
            let value = String(source[cursor..<urlEnd])
            result.append(.link(text: [.text(value)], url: value))
            cursor = urlEnd
            return true
        }

        func unescaped(_ character: Character, from start: String.Index) -> String.Index? {
            var position = start
            var escaped = false
            while position < source.endIndex {
                if source[position] == character && !escaped { return position }
                if source[position] == "\\" && !escaped { escaped = true } else { escaped = false }
                position = source.index(after: position)
            }
            return nil
        }
    }
}

private func isBlank(_ line: String) -> Bool {
    line.allSatisfy(\.isWhitespace)
}

private func leadingSpaces(_ line: String) -> Int {
    var count = 0
    for character in line {
        if character == " " { count += 1 }
        else if character == "\t" { count += 4 }
        else { break }
    }
    return count
}

private func dropLeadingColumns(_ line: String, _ columns: Int) -> String {
    var consumed = 0
    var position = line.startIndex
    while position < line.endIndex, consumed < columns {
        if line[position] == " " { consumed += 1 }
        else if line[position] == "\t" { consumed += 4 }
        else { break }
        position = line.index(after: position)
    }
    return String(line[position...])
}

private func trimUpToThreeSpaces(_ line: String) -> String {
    dropLeadingColumns(line, min(3, leadingSpaces(line)))
}
