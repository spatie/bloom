import Foundation

/// Source positions use one-based lines and UTF-16 columns, matching the native text system.
public struct CodeLocation: Sendable, Hashable {
    public var path: String
    public var line: Int
    public var column: Int

    public init(path: String, line: Int = 1, column: Int = 1) {
        self.path = path
        self.line = max(1, line)
        self.column = max(1, column)
    }

    public func displayPath(relativeTo root: String) -> String {
        let prefix = URL(fileURLWithPath: root).standardizedFileURL.path + "/"
        let normalised = (path as NSString).isAbsolutePath
            ? URL(fileURLWithPath: path).standardizedFileURL.path : path
        return normalised.hasPrefix(prefix) ? String(normalised.dropFirst(prefix.count)) : normalised
    }

    public static func suggestions(_ locations: [CodeLocation], root: String, ignored: Set<String>) -> [CodeLocation] {
        var seen: Set<CodeLocation> = []
        let unique = locations.filter { seen.insert($0).inserted }
        func priority(_ location: CodeLocation) -> Int {
            let path = location.displayPath(relativeTo: root)
            let components = path.split(separator: "/")
            if zip(components, components.dropFirst()).contains(where: { $0 == "vendor" && $1 == "_laravel_idea" }) { return 2 }
            return ignored.contains(path) ? 1 : 0
        }
        return unique.enumerated().sorted {
            let lhs = priority($0.element)
            let rhs = priority($1.element)
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    public static func suggestions(_ locations: [CodeLocation], root: String) async -> [CodeLocation] {
        let paths = locations.map { $0.displayPath(relativeTo: root) }.filter { !($0 as NSString).isAbsolutePath }
        let ignored = await Git.ignoredPaths(among: paths, in: root)
        return suggestions(locations, root: root, ignored: ignored)
    }

    public func matchesSymbol(path: String, root: String, text: String, offset: Int) -> Bool {
        guard displayPath(relativeTo: root) == CodeLocation(path: path).displayPath(relativeTo: root) else { return false }
        let source = text as NSString
        guard offset >= 0, offset < source.length else { return false }
        let position = Self.position(in: text, offset: offset)
        guard position.line == line else { return false }
        let lineRange = source.lineRange(for: NSRange(location: offset, length: 0))
        guard let regex = try? NSRegularExpression(pattern: #"[$\p{L}_][\p{L}\p{N}_]*"#) else { return false }
        return regex.matches(in: text, range: lineRange).contains { match in
            NSLocationInRange(offset, match.range)
                && NSLocationInRange(lineRange.location + column - 1, match.range)
        }
    }

    public static func parse(_ reference: String) -> CodeLocation {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(.*?)(?::(\d+)(?::(\d+))?|#L(\d+)(?:C(\d+))?(?:-L?\d+)?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
        else { return CodeLocation(path: value) }
        let ns = value as NSString
        func number(_ index: Int) -> Int? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
        }
        return CodeLocation(path: ns.substring(with: match.range(at: 1)),
                              line: number(2) ?? number(4) ?? 1,
                              column: number(3) ?? number(5) ?? 1)
    }

    public static func offset(in text: String, line: Int, column: Int = 1) -> Int {
        let ns = text as NSString
        var start = 0
        for _ in 1..<max(1, line) {
            guard start < ns.length else { return ns.length }
            start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0)))
        }
        guard start < ns.length else { return ns.length }
        let range = ns.lineRange(for: NSRange(location: start, length: 0))
        let content = ns.substring(with: range).trimmingCharacters(in: .newlines) as NSString
        var offset = start + min(max(0, column - 1), content.length)
        // A server or a pasted location must not place the caret inside a surrogate pair.
        if offset < ns.length, offset > 0, (0xDC00...0xDFFF).contains(ns.character(at: offset)) { offset -= 1 }
        return offset
    }

    public static func position(in text: String, offset: Int) -> (line: Int, column: Int) {
        let units = Array(text.utf16)
        let end = min(max(0, offset), units.count)
        var line = 1
        var start = 0
        for index in 0..<end where units[index] == 10 { line += 1; start = index + 1 }
        return (line, end - start + 1)
    }
}

public struct SourceHistory: Sendable {
    public private(set) var entries: [CodeLocation] = []
    public private(set) var index = -1
    public init() {}
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < entries.count }

    public mutating func visit(_ location: CodeLocation) {
        guard index < 0 || entries[index] != location else { return }
        entries = Array(entries.prefix(index + 1))
        entries.append(location)
        if entries.count > 100 { entries.removeFirst() }
        index = entries.count - 1
    }

    public mutating func updateCurrent(_ location: CodeLocation) {
        guard entries.indices.contains(index), entries[index].path == location.path else { return }
        entries[index] = location
    }

    public mutating func move(_ delta: Int) -> CodeLocation? {
        let next = index + delta
        guard entries.indices.contains(next) else { return nil }
        index = next
        return entries[index]
    }
}
