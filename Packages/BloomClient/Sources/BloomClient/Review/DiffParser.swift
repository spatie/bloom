import Foundation

// MARK: - Model

/// One line of a hunk, carrying the numbers both gutters need.
///
/// `text` has already had the leading marker removed so a view never has to slice it again, and
/// `index` is a per-file running counter so SwiftUI has a stable identity even when two lines
/// happen to hold the same text.
public struct DiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case context
        case addition
        case deletion
        /// The `\ No newline at end of file` marker. It belongs to whichever side it follows.
        case noNewline
    }

    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
    public var index: Int

    public var id: Int { index }

    public init(
        kind: Kind,
        text: String,
        oldNumber: Int? = nil,
        newNumber: Int? = nil,
        index: Int = 0
    ) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.index = index
    }
}

/// A single `@@` block. The counts are what the header claimed, which can disagree with
/// `lines.count` when a patch was truncated.
public struct DiffHunk: Sendable, Hashable, Identifiable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Everything after the closing `@@`, usually the enclosing function. Keeps its leading space.
    public var header: String
    public var lines: [DiffLine]

    public var id: String { "\(oldStart),\(oldCount),\(newStart),\(newCount)" }

    public init(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        header: String = "",
        lines: [DiffLine] = []
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.header = header
        self.lines = lines
    }
}

/// The parsed diff for one file.
///
/// Both paths are optional because `/dev/null` on either side is how git spells "added" and
/// "deleted", and a mode-only change has no paths in its body at all.
public struct FileDiff: Sendable, Identifiable, Hashable {
    public var oldPath: String?
    public var newPath: String?
    public var hunks: [DiffHunk]
    public var isBinary: Bool
    public var isRename: Bool
    public var oldMode: String?
    public var newMode: String?
    public var additions: Int
    public var deletions: Int

    public var id: String { newPath ?? oldPath ?? "" }

    /// What a file list should show: the destination, falling back to the source for a deletion.
    public var displayPath: String { newPath ?? oldPath ?? "" }

    public var isNew: Bool { oldPath == nil && newPath != nil }
    public var isDeleted: Bool { newPath == nil && oldPath != nil }
    public var isModeChangeOnly: Bool { hunks.isEmpty && !isBinary && oldMode != newMode }

    public init(
        oldPath: String? = nil,
        newPath: String? = nil,
        hunks: [DiffHunk] = [],
        isBinary: Bool = false,
        isRename: Bool = false,
        oldMode: String? = nil,
        newMode: String? = nil,
        additions: Int = 0,
        deletions: Int = 0
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
        self.isBinary = isBinary
        self.isRename = isRename
        self.oldMode = oldMode
        self.newMode = newMode
        self.additions = additions
        self.deletions = deletions
    }
}

/// One row of a two column view. A nil side is padding, drawn as an empty gutter.
public struct SideBySideRow: Sendable, Hashable, Identifiable {
    public var left: DiffLine?
    public var right: DiffLine?
    public var index: Int

    public var id: Int { index }

    /// A deletion sitting opposite an addition, the only case worth an intra-line highlight.
    public var isPaired: Bool { left?.kind == .deletion && right?.kind == .addition }

    public init(left: DiffLine?, right: DiffLine?, index: Int = 0) {
        self.left = left
        self.right = right
        self.index = index
    }
}

// MARK: - Side by side

public extension FileDiff {
    /// Fold the hunks into two column rows.
    ///
    /// Deletions and additions are buffered until something else interrupts them, then paired off
    /// positionally, which is what every diff viewer does and what makes an intra-line highlight
    /// possible. Leftovers on the longer run get a nil opposite them.
    func sideBySide() -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        rows.reserveCapacity(hunks.reduce(0) { $0 + $1.lines.count })

        for hunk in hunks {
            var deletions: [DiffLine] = []
            var additions: [DiffLine] = []
            var leftMarker: DiffLine?
            var rightMarker: DiffLine?
            var previousKind: DiffLine.Kind = .context

            func flush() {
                let count = max(deletions.count, additions.count)
                for offset in 0..<count {
                    rows.append(SideBySideRow(
                        left: offset < deletions.count ? deletions[offset] : nil,
                        right: offset < additions.count ? additions[offset] : nil,
                        index: rows.count
                    ))
                }
                deletions.removeAll(keepingCapacity: true)
                additions.removeAll(keepingCapacity: true)

                if leftMarker != nil || rightMarker != nil {
                    rows.append(SideBySideRow(left: leftMarker, right: rightMarker, index: rows.count))
                    leftMarker = nil
                    rightMarker = nil
                }
            }

            for line in hunk.lines {
                switch line.kind {
                case .deletion:
                    deletions.append(line)
                    previousKind = .deletion
                case .addition:
                    additions.append(line)
                    previousKind = .addition
                case .noNewline:
                    // The marker annotates the line before it, so it never breaks up a run.
                    switch previousKind {
                    case .deletion: leftMarker = line
                    case .addition: rightMarker = line
                    default: leftMarker = line; rightMarker = line
                    }
                case .context:
                    flush()
                    rows.append(SideBySideRow(left: line, right: line, index: rows.count))
                    previousKind = .context
                }
            }
            flush()
        }
        return rows
    }
}

// MARK: - Parser

/// Turns `git diff` output into something renderable.
///
/// The scan runs over UTF-8 bytes rather than Characters: a diff view reparses on every
/// selection change, and grapheme breaking a whole patch to find newlines dominates the cost.
/// Strings are only materialised for the lines that are actually kept.
public enum DiffParser {
    /// Longest line pair we will word-diff. Past this a whole-line highlight is both cheaper and
    /// more honest, since minified or generated lines have no useful word structure.
    public static let intraLineLimit = 2000

    /// Largest token grid the word LCS may allocate, so a pathological line cannot stall the UI.
    private static let lcsCellLimit = 250_000

    // MARK: Public API

    public static func parse(_ patch: String) -> [FileDiff] {
        guard !patch.isEmpty else { return [] }

        let bytes = Array(patch.utf8)
        var files: [FileDiff] = []
        var file: FileDiff?
        var hunk: DiffHunk?
        var oldLine = 0
        var newLine = 0
        var remainingOld = 0
        var remainingNew = 0
        var lineIndex = 0

        func closeHunk() {
            guard let open = hunk else { return }
            file?.hunks.append(open)
            hunk = nil
            remainingOld = 0
            remainingNew = 0
        }

        func closeFile() {
            closeHunk()
            if let open = file { files.append(open) }
            file = nil
            lineIndex = 0
        }

        func ensureFile() {
            if file == nil { file = FileDiff() }
        }

        var cursor = 0
        let end = bytes.count

        while cursor < end {
            var stop = cursor
            while stop < end, bytes[stop] != 0x0A { stop += 1 }
            let slice = bytes[cursor..<stop]
            cursor = stop + 1

            let marker = slice.first
            // The trailing "\ No newline" marker sits outside the hunk's own line budget, so it
            // stays part of the hunk even once the counts are used up.
            let insideHunk = hunk != nil
                && (remainingOld > 0 || remainingNew > 0 || marker == 0x5C)

            if insideHunk, marker == nil {
                // Some tools emit a bare empty line where git would emit a single space.
                hunk?.lines.append(DiffLine(
                    kind: .context, text: "", oldNumber: oldLine, newNumber: newLine, index: lineIndex
                ))
                lineIndex += 1
                oldLine += 1
                newLine += 1
                remainingOld = max(0, remainingOld - 1)
                remainingNew = max(0, remainingNew - 1)
                continue
            }

            if insideHunk, let marker, marker == 0x20 || marker == 0x2B || marker == 0x2D || marker == 0x5C {
                let text = String(decoding: slice.dropFirst(), as: UTF8.self)
                switch marker {
                case 0x20:
                    hunk?.lines.append(DiffLine(
                        kind: .context, text: text, oldNumber: oldLine, newNumber: newLine, index: lineIndex
                    ))
                    oldLine += 1
                    newLine += 1
                    remainingOld = max(0, remainingOld - 1)
                    remainingNew = max(0, remainingNew - 1)
                case 0x2B:
                    hunk?.lines.append(DiffLine(
                        kind: .addition, text: text, newNumber: newLine, index: lineIndex
                    ))
                    newLine += 1
                    remainingNew = max(0, remainingNew - 1)
                    file?.additions += 1
                case 0x2D:
                    hunk?.lines.append(DiffLine(
                        kind: .deletion, text: text, oldNumber: oldLine, index: lineIndex
                    ))
                    oldLine += 1
                    remainingOld = max(0, remainingOld - 1)
                    file?.deletions += 1
                default:
                    // "\ No newline at end of file". Drop the marker and its separating space.
                    hunk?.lines.append(DiffLine(
                        kind: .noNewline,
                        text: text.hasPrefix(" ") ? String(text.dropFirst()) : text,
                        index: lineIndex
                    ))
                }
                lineIndex += 1
                continue
            }

            // Anything else is metadata, and metadata is rare enough to pay for a String.
            let line = String(decoding: slice, as: UTF8.self)

            if line.hasPrefix("diff --git ") {
                closeFile()
                var fresh = FileDiff()
                let (old, new) = gitHeaderPaths(line.dropFirst("diff --git ".count))
                fresh.oldPath = old
                fresh.newPath = new
                file = fresh
            } else if line.hasPrefix("--- ") {
                ensureFile()
                closeHunk()
                file?.oldPath = headerPath(line.dropFirst(4))
            } else if line.hasPrefix("+++ ") {
                ensureFile()
                closeHunk()
                file?.newPath = headerPath(line.dropFirst(4))
            } else if slice.count >= 2, slice.first == 0x40, slice.dropFirst().first == 0x40 {
                ensureFile()
                closeHunk()
                guard let parsed = parseHunkHeader(slice) else { continue }
                hunk = DiffHunk(
                    oldStart: parsed.oldStart,
                    oldCount: parsed.oldCount,
                    newStart: parsed.newStart,
                    newCount: parsed.newCount,
                    header: parsed.header
                )
                oldLine = parsed.oldStart
                newLine = parsed.newStart
                remainingOld = parsed.oldCount
                remainingNew = parsed.newCount
            } else if line.hasPrefix("new file mode ") {
                ensureFile()
                file?.newMode = String(line.dropFirst("new file mode ".count))
            } else if line.hasPrefix("deleted file mode ") {
                ensureFile()
                file?.oldMode = String(line.dropFirst("deleted file mode ".count))
            } else if line.hasPrefix("old mode ") {
                ensureFile()
                file?.oldMode = String(line.dropFirst("old mode ".count))
            } else if line.hasPrefix("new mode ") {
                ensureFile()
                file?.newMode = String(line.dropFirst("new mode ".count))
            } else if line.hasPrefix("rename from ") {
                ensureFile()
                file?.isRename = true
                file?.oldPath = barePath(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                ensureFile()
                file?.isRename = true
                file?.newPath = barePath(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("copy from ") {
                ensureFile()
                file?.oldPath = barePath(line.dropFirst("copy from ".count))
            } else if line.hasPrefix("copy to ") {
                ensureFile()
                file?.newPath = barePath(line.dropFirst("copy to ".count))
            } else if line.hasPrefix("index ") {
                ensureFile()
                let parts = line.components(separatedBy: " ")
                if parts.count >= 3 {
                    let mode = parts[2]
                    if file?.oldMode == nil { file?.oldMode = mode }
                    if file?.newMode == nil { file?.newMode = mode }
                }
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch")
                || (line.hasPrefix("Files ") && line.hasSuffix(" differ")) {
                ensureFile()
                file?.isBinary = true
            }
            // similarity index, dissimilarity index, mode-less noise: nothing to record.
        }

        closeFile()
        return files
    }

    /// Additions and deletions without building the model, for a header badge.
    public static func stats(_ patch: String) -> (additions: Int, deletions: Int) {
        guard !patch.isEmpty else { return (0, 0) }

        let bytes = Array(patch.utf8)
        var additions = 0
        var deletions = 0
        var remainingOld = 0
        var remainingNew = 0
        var cursor = 0
        let end = bytes.count

        while cursor < end {
            var stop = cursor
            while stop < end, bytes[stop] != 0x0A { stop += 1 }
            let slice = bytes[cursor..<stop]
            cursor = stop + 1

            let insideHunk = remainingOld > 0 || remainingNew > 0
            let marker = slice.first

            if insideHunk {
                switch marker {
                case .some(0x20), .none:
                    remainingOld = max(0, remainingOld - 1)
                    remainingNew = max(0, remainingNew - 1)
                    continue
                case .some(0x2B):
                    additions += 1
                    remainingNew = max(0, remainingNew - 1)
                    continue
                case .some(0x2D):
                    deletions += 1
                    remainingOld = max(0, remainingOld - 1)
                    continue
                case .some(0x5C):
                    continue
                default:
                    break
                }
            }

            if slice.count >= 2, slice.first == 0x40, slice.dropFirst().first == 0x40,
               let parsed = parseHunkHeader(slice) {
                remainingOld = parsed.oldCount
                remainingNew = parsed.newCount
            } else {
                remainingOld = 0
                remainingNew = 0
            }
        }

        return (additions, deletions)
    }

    // MARK: Intra-line highlighting

    /// Word level ranges that differ between a paired deletion and addition.
    ///
    /// A common prefix and suffix are trimmed first, which alone resolves most edits, then the
    /// remaining middles go through a token LCS. Anything longer than `intraLineLimit` bytes falls
    /// back to highlighting the whole line, because the grid would cost more than the view is worth.
    public static func intraLineDiff(
        _ before: String,
        _ after: String
    ) -> (before: [Range<String.Index>], after: [Range<String.Index>]) {
        if before == after { return ([], []) }
        if before.isEmpty { return ([], [after.startIndex..<after.endIndex]) }
        if after.isEmpty { return ([before.startIndex..<before.endIndex], []) }

        if before.utf8.count > intraLineLimit || after.utf8.count > intraLineLimit {
            return ([before.startIndex..<before.endIndex], [after.startIndex..<after.endIndex])
        }

        var beforeStart = before.startIndex
        var afterStart = after.startIndex
        while beforeStart < before.endIndex, afterStart < after.endIndex,
              before[beforeStart] == after[afterStart] {
            beforeStart = before.index(after: beforeStart)
            afterStart = after.index(after: afterStart)
        }

        var beforeEnd = before.endIndex
        var afterEnd = after.endIndex
        while beforeEnd > beforeStart, afterEnd > afterStart {
            let previousBefore = before.index(before: beforeEnd)
            let previousAfter = after.index(before: afterEnd)
            guard before[previousBefore] == after[previousAfter] else { break }
            beforeEnd = previousBefore
            afterEnd = previousAfter
        }

        // Character trimming happily stops halfway through a word, because "alpha" and "gamma"
        // share a trailing "a". Push both boundaries back out to word edges so a highlight covers
        // the whole word a reader is comparing.
        while beforeEnd < before.endIndex, afterEnd < after.endIndex,
              isWordCharacter(before[beforeEnd]),
              (beforeEnd > beforeStart && isWordCharacter(before[before.index(before: beforeEnd)]))
                || (afterEnd > afterStart && isWordCharacter(after[after.index(before: afterEnd)])) {
            beforeEnd = before.index(after: beforeEnd)
            afterEnd = after.index(after: afterEnd)
        }
        while beforeStart > before.startIndex, afterStart > after.startIndex,
              isWordCharacter(before[before.index(before: beforeStart)]),
              (beforeStart < beforeEnd && isWordCharacter(before[beforeStart]))
                || (afterStart < afterEnd && isWordCharacter(after[afterStart])) {
            beforeStart = before.index(before: beforeStart)
            afterStart = after.index(before: afterStart)
        }

        let beforeMiddle = before[beforeStart..<beforeEnd]
        let afterMiddle = after[afterStart..<afterEnd]

        if beforeMiddle.isEmpty { return ([], afterMiddle.isEmpty ? [] : [afterStart..<afterEnd]) }
        if afterMiddle.isEmpty { return ([beforeStart..<beforeEnd], []) }

        let beforeTokens = tokenize(beforeMiddle)
        let afterTokens = tokenize(afterMiddle)
        let rows = beforeTokens.count
        let columns = afterTokens.count

        guard rows * columns <= lcsCellLimit else {
            return ([beforeStart..<beforeEnd], [afterStart..<afterEnd])
        }

        // Suffix LCS table, walked forward afterwards to mark what survived.
        let width = columns + 1
        var table = [Int](repeating: 0, count: (rows + 1) * width)
        if rows > 0, columns > 0 {
            for row in (0..<rows).reversed() {
                for column in (0..<columns).reversed() {
                    table[row * width + column] = beforeTokens[row].text == afterTokens[column].text
                        ? table[(row + 1) * width + column + 1] + 1
                        : max(table[(row + 1) * width + column], table[row * width + column + 1])
                }
            }
        }

        var beforeKept = [Bool](repeating: false, count: rows)
        var afterKept = [Bool](repeating: false, count: columns)
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if beforeTokens[row].text == afterTokens[column].text {
                beforeKept[row] = true
                afterKept[column] = true
                row += 1
                column += 1
            } else if table[(row + 1) * width + column] >= table[row * width + column + 1] {
                row += 1
            } else {
                column += 1
            }
        }

        return (
            changedRanges(beforeTokens, kept: beforeKept),
            changedRanges(afterTokens, kept: afterKept)
        )
    }

    private struct Token {
        var range: Range<String.Index>
        var text: Substring
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Words, whitespace runs and single punctuation characters. Punctuation stays separate so a
    /// changed argument does not drag the surrounding parentheses into the highlight.
    private static func tokenize(_ input: Substring) -> [Token] {
        var tokens: [Token] = []
        var cursor = input.startIndex

        while cursor < input.endIndex {
            let start = cursor
            let character = input[cursor]
            if isWordCharacter(character) {
                while cursor < input.endIndex, isWordCharacter(input[cursor]) {
                    cursor = input.index(after: cursor)
                }
            } else if character.isWhitespace {
                while cursor < input.endIndex, input[cursor].isWhitespace {
                    cursor = input.index(after: cursor)
                }
            } else {
                cursor = input.index(after: cursor)
            }
            tokens.append(Token(range: start..<cursor, text: input[start..<cursor]))
        }
        return tokens
    }

    private static func changedRanges(_ tokens: [Token], kept: [Bool]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for (offset, token) in tokens.enumerated() where !kept[offset] {
            if let last = ranges.last, last.upperBound == token.range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<token.range.upperBound
            } else {
                ranges.append(token.range)
            }
        }
        return ranges
    }

    // MARK: Header parsing

    private static func parseHunkHeader(
        _ slice: ArraySlice<UInt8>
    ) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, header: String)? {
        var cursor = slice.startIndex
        let end = slice.endIndex

        func skipAts() {
            while cursor < end, slice[cursor] == 0x40 { cursor += 1 }
        }
        func skipSpaces() {
            while cursor < end, slice[cursor] == 0x20 { cursor += 1 }
        }
        func readInt() -> Int? {
            var value = 0
            var digits = 0
            while cursor < end, slice[cursor] >= 0x30, slice[cursor] <= 0x39 {
                value = value * 10 + Int(slice[cursor] - 0x30)
                digits += 1
                cursor += 1
                if digits > 12 { return nil }
            }
            return digits > 0 ? value : nil
        }
        func readRange(_ sign: UInt8) -> (Int, Int)? {
            skipSpaces()
            guard cursor < end, slice[cursor] == sign else { return nil }
            cursor += 1
            guard let start = readInt() else { return nil }
            guard cursor < end, slice[cursor] == 0x2C else { return (start, 1) }
            cursor += 1
            guard let count = readInt() else { return nil }
            return (start, count)
        }

        skipAts()
        guard let old = readRange(0x2D), let new = readRange(0x2B) else { return nil }
        skipSpaces()
        skipAts()

        return (old.0, old.1, new.0, new.1, String(decoding: slice[cursor..<end], as: UTF8.self))
    }

    /// The path on a `---` or `+++` line. Git quotes unusual bytes and, for a plain name holding
    /// a space, terminates it with a tab instead.
    private static func headerPath(_ value: Substring) -> String? {
        if value.hasPrefix("\"") { return stripSourcePrefix(unquote(value)) }
        var path = value
        if let tab = path.firstIndex(of: "\t") { path = path[..<tab] }
        return stripSourcePrefix(String(path))
    }

    /// The path on a `rename from` or `copy to` line, which carries no a/ or b/ prefix.
    private static func barePath(_ value: Substring) -> String? {
        value.hasPrefix("\"") ? unquote(value) : String(value)
    }

    /// Both paths off a `diff --git` line.
    ///
    /// The line is ambiguous by construction: a space separates two paths that may themselves hold
    /// spaces. Splitting on a space followed by `b/` and preferring the split where the two sides
    /// match resolves every case git can actually produce, and the `---`/`+++` lines correct us
    /// afterwards whenever a body follows.
    private static func gitHeaderPaths(_ rest: Substring) -> (String?, String?) {
        if rest.hasPrefix("\"") {
            guard let (first, remainder) = takeQuoted(rest) else { return (nil, nil) }
            let second = remainder.drop(while: { $0 == " " })
            let right = second.hasPrefix("\"") ? (takeQuoted(second)?.0 ?? String(second)) : String(second)
            return (stripSourcePrefix(first), stripSourcePrefix(right))
        }

        let characters = Array(rest)
        var candidates: [Int] = []
        for offset in characters.indices where characters[offset] == " " {
            if offset + 2 < characters.count, characters[offset + 1] == "b", characters[offset + 2] == "/" {
                candidates.append(offset)
            }
        }
        guard !candidates.isEmpty else {
            guard let space = rest.firstIndex(of: " ") else { return (nil, nil) }
            return (
                stripSourcePrefix(String(rest[..<space])),
                stripSourcePrefix(String(rest[rest.index(after: space)...]))
            )
        }

        var fallback: (String?, String?)?
        for candidate in candidates {
            let left = stripSourcePrefix(String(characters[0..<candidate]))
            let right = stripSourcePrefix(String(characters[(candidate + 1)...]))
            if left == right { return (left, right) }
            if fallback == nil { fallback = (left, right) }
        }
        return fallback ?? (nil, nil)
    }

    private static func takeQuoted(_ input: Substring) -> (String, Substring)? {
        guard input.hasPrefix("\"") else { return nil }
        var cursor = input.index(after: input.startIndex)
        while cursor < input.endIndex {
            let character = input[cursor]
            if character == "\\" {
                cursor = input.index(after: cursor)
                if cursor < input.endIndex { cursor = input.index(after: cursor) }
                continue
            }
            if character == "\"" {
                let after = input.index(after: cursor)
                return (unquote(input[input.startIndex...cursor]), input[after...])
            }
            cursor = input.index(after: cursor)
        }
        return nil
    }

    /// Decode git's C-style quoting, including the octal escapes it uses for non-ASCII bytes.
    private static func unquote(_ input: Substring) -> String {
        var body = input
        if body.hasPrefix("\"") { body = body.dropFirst() }
        if body.hasSuffix("\"") { body = body.dropLast() }

        let bytes = Array(body.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var cursor = 0

        while cursor < bytes.count {
            let byte = bytes[cursor]
            guard byte == 0x5C, cursor + 1 < bytes.count else {
                output.append(byte)
                cursor += 1
                continue
            }
            let next = bytes[cursor + 1]
            switch next {
            case UInt8(ascii: "n"): output.append(0x0A); cursor += 2
            case UInt8(ascii: "t"): output.append(0x09); cursor += 2
            case UInt8(ascii: "r"): output.append(0x0D); cursor += 2
            case UInt8(ascii: "b"): output.append(0x08); cursor += 2
            case UInt8(ascii: "f"): output.append(0x0C); cursor += 2
            case UInt8(ascii: "v"): output.append(0x0B); cursor += 2
            case UInt8(ascii: "a"): output.append(0x07); cursor += 2
            case UInt8(ascii: "\""), UInt8(ascii: "\\"): output.append(next); cursor += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = 0
                var digits = 0
                var scan = cursor + 1
                while scan < bytes.count, digits < 3,
                      bytes[scan] >= UInt8(ascii: "0"), bytes[scan] <= UInt8(ascii: "7") {
                    value = value * 8 + Int(bytes[scan] - UInt8(ascii: "0"))
                    digits += 1
                    scan += 1
                }
                output.append(UInt8(truncatingIfNeeded: value))
                cursor = scan
            default:
                output.append(next)
                cursor += 2
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func stripSourcePrefix(_ path: String) -> String? {
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }
}
