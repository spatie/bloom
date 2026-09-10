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
