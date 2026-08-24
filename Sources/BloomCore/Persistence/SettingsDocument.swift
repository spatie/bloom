import Foundation

/// A value the settings editor knows how to write back into a TOML file.
public enum TOMLLiteral: Sendable, Hashable {
    case string(String)
    case boolean(Bool)
    case strings([String])
}

/// One settings file, edited in place as text rather than reparsed and reprinted.
///
/// The whole point is that a settings file is a file a person wrote. It has comments, an ordering
/// they chose, a `$schema` line at the top, and quite possibly keys this app has never heard of.
/// Round-tripping it through `TOML.parse` and a serialiser would hand it back reordered, stripped
/// of comments, and missing anything the parser reduced. So edits are surgical: find the lines the
/// key occupies, replace exactly those, and leave every other byte of the file alone.
///
/// That also settles what happens when the file changes on disk while the settings window is open.
/// A write only ever touches the key being written, so a change someone else made to a different
/// key survives it. The window rereads the file when it comes back to the front, so the screen
/// catches up too.
public struct SettingsDocument: Sendable, Equatable {
    private var lines: [String]
    /// Whether the source ended with a newline, so a rewritten file keeps the same shape.
    private var hadTrailingNewline: Bool
    /// False when the file did not exist. A document that is still empty and still absent is not
    /// worth creating, which is how "nothing was configured" avoids littering empty files.
    public private(set) var exists: Bool

    public init(text: String, exists: Bool = true) {
        hadTrailingNewline = text.isEmpty || text.hasSuffix("\n")
        var body = text
        if hadTrailingNewline, !body.isEmpty { body.removeLast() }
        lines = body.isEmpty ? [] : body.components(separatedBy: "\n")
        self.exists = exists
    }

    /// Reads the file, or an empty document when there is none.
    public init(contentsOf path: String) {
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            self.init(text: text, exists: true)
        } else {
            self.init(text: "", exists: false)
        }
    }

    public var text: String {
        let body = lines.joined(separator: "\n")
        if body.isEmpty { return "" }
        return hadTrailingNewline ? body + "\n" : body
    }

    public var isEmpty: Bool {
        lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Writing

    /// Sets `path` to `value`, replacing the lines the key already occupies or appending it to the
    /// table it belongs in.
    public mutating func set(_ value: TOMLLiteral, at path: [String]) {
        guard !path.isEmpty else { return }
        let rendered = Self.render(value)

        if let found = locate(path) {
            let replacement = "\(found.indent)\(found.writtenKey) = \(rendered)"
            lines.replaceSubrange(found.range, with: replacement.components(separatedBy: "\n"))
            return
        }

        insert(key: path.last!, rendered: rendered, inTable: Array(path.dropLast()))
    }

    /// Removes `path` entirely. Nothing happens when it is not there.
    public mutating func remove(at path: [String]) {
        guard let found = locate(path) else { return }
        lines.removeSubrange(found.range)
    }

    /// Removes a `[table]` header and everything under it, up to the next header.
    public mutating func removeTable(at path: [String]) {
        guard let range = tableRange(path), let header = headerIndex(path) else { return }
        lines.removeSubrange(header..<range.upperBound)
    }

    /// Every table declared directly under `path`, in file order. `["scripts", "run"]` gives back
    /// `[["scripts", "run", "dev"], ["scripts", "run", "test"]]`.
    public func tables(under path: [String]) -> [[String]] {
        lines.compactMap { line in
            guard let header = Self.tableHeader(in: line) else { return nil }
            guard header.count == path.count + 1, Array(header.dropLast()) == path else { return nil }
            return header
        }
    }

    public func write(to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Rendering

    /// A TOML literal for `value`.
    ///
    /// Multi-line strings get the literal `'''` form, which is what a shell script wants: it has
    /// no escapes, so `$PATH`, `\n` inside a `sed` expression and a Windows path all survive being
    /// written and read back. A script that itself contains `'''` cannot use it, and falls back to
    /// the escaped `"""` form.
    static func render(_ value: TOMLLiteral) -> String {
        switch value {
        case .boolean(let flag):
            return flag ? "true" : "false"
        case .strings(let items):
            return "[" + items.map { quoted($0) }.joined(separator: ", ") + "]"
        case .string(let text):
            guard text.contains("\n") else { return quoted(text) }
            if !text.contains("'''") {
                return "'''\n\(text)\n'''"
            }
            return "\"\"\"\n\(escaped(text))\n\"\"\""
        }
    }

    /// Double quotes, which is what settings files are written in, unless the value carries a
    /// backslash: a Windows path, or a `sed` expression escaped for TOML, is unreadable that way,
    /// and the literal `'...'` form keeps it exactly as typed.
    private static func quoted(_ text: String) -> String {
        if text.contains("\\"), !text.contains("'"), !text.contains("\n") {
            return "'\(text)'"
        }
        return "\"\(escaped(text))\""
    }

    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text.unicodeScalars {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default: result.unicodeScalars.append(character)
            }
        }
        return result
    }

    // MARK: - Locating

    private struct Located {
        var range: Range<Int>
        var indent: String
        /// The key exactly as the file spells it, so replacing `scripts.setup = x` at the root
        /// does not silently move the key into a `[scripts]` table that is not there.
        var writtenKey: String
    }

    /// Finds `path` however the file happens to spell it: as a key inside its own `[table]`, or as
    /// a dotted key inside any ancestor table, including the root.
    private func locate(_ path: [String]) -> Located? {
        for split in stride(from: path.count - 1, through: 0, by: -1) {
            let table = Array(path.prefix(split))
            let key = Array(path.dropFirst(split))
            guard let range = tableRange(table) else { continue }
            if let found = findKey(key, in: range) { return found }
        }
        return nil
    }

    /// The line index of `[table]`'s header, or nil for the root table and for a table that is
    /// not declared.
    private func headerIndex(_ table: [String]) -> Int? {
        guard !table.isEmpty else { return nil }
        return lines.firstIndex { Self.tableHeader(in: $0) == table }
    }

    /// The lines belonging to `table`, not counting its header. The root table is everything
    /// before the first header.
    private func tableRange(_ table: [String]) -> Range<Int>? {
        var start: Int
        if table.isEmpty {
            start = 0
        } else {
            guard let header = headerIndex(table) else { return nil }
            start = header + 1
        }
        var end = start
        while end < lines.count, Self.tableHeader(in: lines[end]) == nil {
            end += 1
        }
        return start..<end
    }

    private func findKey(_ key: [String], in range: Range<Int>) -> Located? {
        for index in range {
            guard let (written, indent) = Self.keyAssignment(in: lines[index]), written == key else {
                continue
            }
            let end = valueEnd(startingAt: index)
            return Located(
                range: index..<end,
                indent: indent,
                writtenKey: key.map { Self.needsQuoting($0) ? "\"\($0)\"" : $0 }.joined(separator: ".")
            )
        }
        return nil
    }

    /// One past the last line of the value that starts on `index`.
    ///
    /// A value is usually one line, but a script is a `'''` block and a glob list can be split
    /// over several, and replacing only the first line of either would leave the rest of the old
    /// value behind as garbage.
    private func valueEnd(startingAt index: Int) -> Int {
        guard let equals = lines[index].firstIndex(of: "=") else { return index + 1 }
        let value = String(lines[index][lines[index].index(after: equals)...])
            .trimmingCharacters(in: .whitespaces)

        for delimiter in ["'''", "\"\"\""] where value.hasPrefix(delimiter) {
            // A single-line `'''x'''` closes on its own line.
            if value.dropFirst(delimiter.count).contains(delimiter) { return index + 1 }
            var cursor = index + 1
            while cursor < lines.count {
                if lines[cursor].contains(delimiter) { return cursor + 1 }
                cursor += 1
            }
            return lines.count
        }

        if value.hasPrefix("[") || value.hasPrefix("{") {
            let open: Character = value.hasPrefix("[") ? "[" : "{"
            let close: Character = open == "[" ? "]" : "}"
            var depth = 0
            var cursor = index
            while cursor < lines.count {
                depth += Self.balance(lines[cursor], open: open, close: close)
                if depth <= 0 { return cursor + 1 }
                cursor += 1
            }
            return lines.count
        }

        return index + 1
    }

    /// The net bracket depth a line adds, ignoring brackets inside strings and comments.
    private static func balance(_ line: String, open: Character, close: Character) -> Int {
        var depth = 0
        var quote: Character?
        for character in line {
            if let active = quote {
                if character == active { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "#": return depth
            case open: depth += 1
            case close: depth -= 1
            default: break
            }
        }
        return depth
    }

    // MARK: - Inserting

    private mutating func insert(key: String, rendered: String, inTable table: [String]) {
        let line = "\(Self.needsQuoting(key) ? "\"\(key)\"" : key) = \(rendered)"

        if let range = tableRange(table) {
            // After the table's last non-blank line, so a blank line separating tables stays a
            // separator rather than becoming a gap in the middle of one.
            var insertion = range.upperBound
            while insertion > range.lowerBound,
                  lines[insertion - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertion -= 1
            }
            lines.insert(contentsOf: line.components(separatedBy: "\n"), at: insertion)
            return
        }

        if !lines.isEmpty, !(lines.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
            lines.append("")
        }
        let header = "[" + table.map { Self.needsQuoting($0) ? "\"\($0)\"" : $0 }.joined(separator: ".") + "]"
        lines.append(header)
        lines.append(contentsOf: line.components(separatedBy: "\n"))
    }

    // MARK: - Line shapes

    private static func needsQuoting(_ key: String) -> Bool {
        key.isEmpty || key.contains { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The table path a `[a.b]` or `[[a.b]]` header names, or nil for any other line.
    static func tableHeader(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        var inner = trimmed.dropFirst().dropLast()
        if inner.hasPrefix("["), inner.hasSuffix("]") {
            inner = inner.dropFirst().dropLast()
        }
        let path = splitKey(String(inner))
        return path.isEmpty ? nil : path
    }

    /// The key a `key = value` line assigns, with the indentation in front of it.
    static func keyAssignment(in line: String) -> ([String], String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let head = String(line[line.startIndex..<equals])
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("[") else { return nil }
        let indent = String(head.prefix { $0 == " " || $0 == "\t" })
        let path = splitKey(trimmed)
        return path.isEmpty ? nil : (path, indent)
    }

    /// Splits a dotted key, honouring quotes, so `"a.b".c` is two components and not three.
    static func splitKey(_ text: String) -> [String] {
        var components: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case ".":
                components.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default: current.append(character)
            }
        }
        components.append(current.trimmingCharacters(in: .whitespaces))
        return components.filter { !$0.isEmpty }
    }
}
