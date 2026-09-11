import Foundation

public struct SourceEdit: Sendable, Equatable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange
}

/// Pure editing operations so indentation, Unicode and trailing selections can be tested without AppKit.
public enum SourceEditing {
    public enum Command: Sendable { case indent, outdent, comment }

    public static func indentation(in text: String) -> String {
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            let prefix = String(line.prefix { $0 == " " || $0 == "\t" })
            if prefix.contains("\t") { return "\t" }
            if prefix.count >= 2 { return String(repeating: " ", count: min(prefix.count, 4)) }
        }
        return "    "
    }

    public static func newline(in text: String, selection: NSRange) -> SourceEdit {
        let ns = text as NSString
        let start = min(selection.location, ns.length)
        let line = ns.lineRange(for: NSRange(location: start, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: start - line.location))
        let prefix = String(before.prefix { $0 == " " || $0 == "\t" })
        let extra = ["{", "[", "(", ":"].contains(String(before.trimmingCharacters(in: .whitespaces).suffix(1)))
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let replacement = newline + prefix + (extra ? indentation(in: text) : "")
        return SourceEdit(range: selection, replacement: replacement,
                          selection: NSRange(location: start + replacement.utf16.count, length: 0))
    }

    public static func lines(in text: String, selection: NSRange, command: Command, language: Language) -> SourceEdit? {
        let ns = text as NSString
        guard selection.location <= ns.length, NSMaxRange(selection) <= ns.length else { return nil }
        // A selection ending at the beginning of a line does not include that next line.
        let touched = NSRange(location: selection.location, length: max(0, selection.length - 1))
        let range = ns.lineRange(for: touched)
        let original = ns.substring(with: range)
        var lines = original.components(separatedBy: "\n")
        let trailing = lines.last == "" && lines.count > 1
        if trailing { lines.removeLast() }
        let indent = indentation(in: text)
        let marker: String
        switch language {
        case .python, .ruby, .shell, .yaml, .toml: marker = "#"
        case .sql: marker = "--"
        case .html, .xml, .vue, .blade, .markdown: marker = "<!--"
        case .json, .plainText: return command == .comment ? nil : transform(lines, trailing: trailing, range: range, indent: indent, command: command, marker: "//")
        default: marker = "//"
        }
        return transform(lines, trailing: trailing, range: range, indent: indent, command: command, marker: marker)
    }

    private static func transform(_ lines: [String], trailing: Bool, range: NSRange, indent: String,
                                  command: Command, marker: String) -> SourceEdit {
        let nonempty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let uncomment = !nonempty.isEmpty && nonempty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(marker) }
        let changed = lines.map { line -> String in
            switch command {
            case .indent: return indent + line
            case .outdent:
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(min(indent.count, line.prefix { $0 == " " }.count)))
            case .comment:
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return line }
                let prefix = String(line.prefix { $0 == " " || $0 == "\t" })
                var body = String(line.dropFirst(prefix.count))
                let cr = body.hasSuffix("\r") ? "\r" : ""
                if !cr.isEmpty { body.removeLast() }
                if uncomment {
                    body = String(body.dropFirst(marker.count))
                    if body.hasPrefix(" ") { body.removeFirst() }
                    if marker == "<!--", body.hasSuffix(" -->") { body = String(body.dropLast(4)) }
                    return prefix + body + cr
                }
                return prefix + marker + " " + body + (marker == "<!--" ? " -->" : "") + cr
            }
        }.joined(separator: "\n") + (trailing ? "\n" : "")
        return SourceEdit(range: range, replacement: changed,
                          selection: NSRange(location: range.location, length: changed.utf16.count))
    }

    public static func matchingBracket(in text: String, at offset: Int, language: Language) -> Int? {
        let units = Array(text.utf16)
        guard units.indices.contains(offset) else { return nil }
        let pairs: [UInt16: UInt16] = [40: 41, 91: 93, 123: 125, 41: 40, 93: 91, 125: 123]
        guard let partner = pairs[units[offset]] else { return nil }
        var ignored = Set<Int>()
        var base = 0
        for (line, tokens) in zip(text.components(separatedBy: "\n"), SyntaxHighlighter.tokenize(source: text, language: language)) {
            for token in tokens where token.kind == .comment || token.kind == .string {
                for position in token.range { ignored.insert(base + position) }
            }
            base += line.utf16.count + 1
        }
        guard !ignored.contains(offset) else { return nil }
        let step = [40, 91, 123].contains(units[offset]) ? 1 : -1
        var depth = 1
        var cursor = offset + step
        while units.indices.contains(cursor) {
            if !ignored.contains(cursor) {
                if units[cursor] == units[offset] { depth += 1 }
                if units[cursor] == partner { depth -= 1 }
                if depth == 0 { return cursor }
            }
            cursor += step
        }
        return nil
    }
}
