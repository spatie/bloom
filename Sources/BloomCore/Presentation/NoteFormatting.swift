import Foundation

/// Markdown toolbar edits in the UTF-16 coordinates used by NSTextView. Edits are applied from
/// the end backwards, preserving the selected text and making the whole action one undo step.
public enum NoteFormatting {
    public enum Action: Sendable, Equatable {
        case bold, italic, code, codeBlock, bulletList, numberedList, quote
        case heading(Int)
        case link(String)
    }

    public struct Replacement: Sendable, Equatable {
        public let range: NSRange
        public let text: String
    }

    public struct Edit: Sendable, Equatable {
        public let replacements: [Replacement]
        public let selection: NSRange
    }

    public static func edit(_ action: Action, text: String, selection: NSRange) -> Edit? {
        let source = text as NSString
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= source.length, selection.length <= source.length - selection.location else { return nil }
        switch action {
        case .bold: return inline("**", sample: "bold text", source: source, selection: selection)
        case .italic: return inline("*", sample: "italic text", source: source, selection: selection)
        case .code:
            let selected = source.substring(with: selection)
            let end = NSMaxRange(selection)
            // Padding separates a backtick inside the code from its Markdown delimiter.
            if selection.location > 0, end < source.length,
               source.character(at: selection.location - 1) == 32, source.character(at: end) == 32 {
                let left = markerCount(before: selection.location - 1, in: source, character: 96)
                let right = markerCount(after: end + 1, in: source, character: 96)
                if left > 0, left == right {
                    return Edit(replacements: [
                        .init(range: NSRange(location: end, length: right + 1), text: ""),
                        .init(range: NSRange(location: selection.location - left - 1, length: left + 1), text: ""),
                    ], selection: NSRange(location: selection.location - left - 1, length: selection.length))
                }
            }
            let leading = selected.prefix { $0 == "`" }.count
            let trailing = selected.reversed().prefix { $0 == "`" }.count
            let before = markerCount(before: selection.location, in: source, character: 96)
            let after = markerCount(after: NSMaxRange(selection), in: source, character: 96)
            let longest = selected.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let width: Int
            if before > 0, before == after {
                width = before
            } else if leading > 0, leading == trailing, selected.count >= leading * 2 {
                width = leading
            } else {
                width = longest + 1
            }
            let marker = String(repeating: "`", count: width)
            let isWrapped = before > 0 && before == after || leading > 0 && leading == trailing && selected.count >= leading * 2
            if !isWrapped, selected.hasPrefix("`") || selected.hasSuffix("`") {
                return wrap(prefix: marker + " ", suffix: " " + marker, sample: "code", selection: selection)
            }
            return inline(marker, sample: "code", source: source, selection: selection)
        case .link(let url):
            let destination = url.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
            guard !destination.isEmpty else { return nil }
            return wrap(prefix: "[", suffix: "](\(destination))", sample: "link text", selection: selection)
        case .codeBlock:
            let leading = selection.location > 0 && source.character(at: selection.location - 1) != 10 ? "\n" : ""
            let end = NSMaxRange(selection)
            let trailing = end < source.length && source.character(at: end) != 10 ? "\n" : ""
            return wrap(prefix: "\(leading)```\n", suffix: "\n```\(trailing)", sample: "code", selection: selection)
        case .heading(let level):
            guard (1...6).contains(level) else { return nil }
            return lines(action, source: source, selection: selection)
        case .bulletList, .numberedList, .quote:
            return lines(action, source: source, selection: selection)
        }
    }

    private static func wrap(prefix: String, suffix: String, sample: String, selection: NSRange) -> Edit {
        let offset = (prefix as NSString).length
        if selection.length == 0 {
            return Edit(replacements: [.init(range: selection, text: prefix + sample + suffix)],
                        selection: NSRange(location: selection.location + offset, length: (sample as NSString).length))
        }
        return Edit(replacements: [
            .init(range: NSRange(location: NSMaxRange(selection), length: 0), text: suffix),
            .init(range: NSRange(location: selection.location, length: 0), text: prefix),
        ], selection: NSRange(location: selection.location + offset, length: selection.length))
    }

    private static func inline(_ marker: String, sample: String, source: NSString, selection: NSRange) -> Edit {
        let width = (marker as NSString).length
        let end = NSMaxRange(selection)
        if selection.location >= width, end + width <= source.length,
           source.substring(with: NSRange(location: selection.location - width, length: width)) == marker,
           source.substring(with: NSRange(location: end, length: width)) == marker,
           marker != "*" || (markerCount(before: selection.location, in: source) % 2 == 1 && markerCount(after: end, in: source) % 2 == 1) {
            return Edit(replacements: [
                .init(range: NSRange(location: end, length: width), text: ""),
                .init(range: NSRange(location: selection.location - width, length: width), text: ""),
            ], selection: NSRange(location: selection.location - width, length: selection.length))
        }
        if selection.length >= width * 2 {
            let selected = source.substring(with: selection)
            let hasItalic = selected.prefix { $0 == "*" }.count % 2 == 1
                && selected.reversed().prefix { $0 == "*" }.count % 2 == 1
            if selected.hasPrefix(marker), selected.hasSuffix(marker), marker != "*" || hasItalic {
                return Edit(replacements: [
                    .init(range: NSRange(location: end - width, length: width), text: ""),
                    .init(range: NSRange(location: selection.location, length: width), text: ""),
                ], selection: NSRange(location: selection.location, length: selection.length - width * 2))
            }
        }
        return wrap(prefix: marker, suffix: marker, sample: sample, selection: selection)
    }

    private static func markerCount(before location: Int, in source: NSString, character: unichar = 42) -> Int {
        var count = 0
        while location - count > 0, source.character(at: location - count - 1) == character { count += 1 }
        return count
    }

    private static func markerCount(after location: Int, in source: NSString, character: unichar = 42) -> Int {
        var count = 0
        while location + count < source.length, source.character(at: location + count) == character { count += 1 }
        return count
    }

    private static func lines(_ action: Action, source: NSString, selection: NSRange) -> Edit {
        // A selection ending at the start of a line does not include that next line.
        var target = selection
        if target.length > 0, source.character(at: NSMaxRange(target) - 1) == 10 { target.length -= 1 }
        let range = source.lineRange(for: target)
        let body = source.substring(with: range)
        let values = body.components(separatedBy: "\n")
        var rows: [(range: NSRange, existing: String, wanted: String)] = []
        var offset = range.location
        var number = 1
        for (index, line) in values.enumerated() {
            defer { offset += (line as NSString).length + 1 }
            if line.isEmpty, values.count > 1 { continue }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let content = String(line.dropFirst(indent.count))
            let existing = prefix(in: content, for: action)
            let wanted: String
            switch action {
            case .heading(let level): wanted = String(repeating: "#", count: level) + " "
            case .bulletList: wanted = "- "
            case .numberedList: wanted = "\(number). "
            case .quote: wanted = "> "
            default: wanted = ""
            }
            if index == values.count - 1, offset > source.length { continue }
            rows.append((NSRange(location: offset + (indent as NSString).length, length: (existing as NSString).length), existing, wanted))
            number += 1
        }
        let remove = !rows.isEmpty && rows.allSatisfy { row in
            switch action {
            case .heading: row.existing == row.wanted
            default: !row.existing.isEmpty
            }
        }
        let changes = rows.map { Replacement(range: $0.range, text: remove ? "" : $0.wanted) }
        let delta = changes.reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
        let firstPrefix = remove ? 0 : (rows.first.map { ($0.wanted as NSString).length } ?? 0)
        return Edit(replacements: Array(changes.reversed()), selection: NSRange(
            location: min(source.length + delta, range.location + firstPrefix),
            length: max(0, range.length + delta - firstPrefix)
        ))
    }

    private static func prefix(in line: String, for action: Action) -> String {
        switch action {
        case .heading:
            let hashes = line.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).hasPrefix(" ") else { return "" }
            return String(hashes) + " "
        case .bulletList:
            return ["- ", "* ", "+ "].first { line.hasPrefix($0) } ?? ""
        case .numberedList:
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return "" }
            return String(digits) + ". "
        case .quote: return line.hasPrefix("> ") ? "> " : ""
        default: return ""
        }
    }
}
