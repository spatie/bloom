import Foundation

public struct SourceMatch: Sendable, Identifiable, Hashable {
    public var location: CodeLocation
    public var text: String
    public var id: CodeLocation { location }
    public init(location: CodeLocation, text: String) { self.location = location; self.text = text }
}

public enum SourceSearch {
    /// Uses the same ignored-file policy as the file picker and bounds both reads and results.
    public static func search(root: String, paths: [String], query: String, limit: Int = 200) throws -> [SourceMatch] {
        guard !query.isEmpty else { return [] }
        var found: [SourceMatch] = []
        for path in paths {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: root).appendingPathComponent(path).resolvingSymlinksInPath()
            let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/"
            guard url.path.hasPrefix(base),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576,
                  let text = try? String(contentsOf: url, encoding: .utf8), !text.contains("\0") else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if let range = line.range(of: query, options: .caseInsensitive) {
                    found.append(SourceMatch(location: CodeLocation(path: path, line: index + 1,
                        column: NSRange(range, in: line).location + 1), text: String(line.prefix(400))))
                    if found.count >= limit { return found }
                }
            }
        }
        return found
    }

    public static func symbols(in text: String, path: String) -> [SourceMatch] {
        let pattern = #"\b(?:func|function|class|struct|enum|actor|protocol|interface|trait|def|fn|type|module)\s+([\p{L}_$][\p{L}\p{N}_$]*)|\b(?:const|let|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)\s*="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let lines = text.components(separatedBy: "\n")
        let tokens = SyntaxHighlighter.tokenize(source: text, language: Language.detect(path: path))
        return lines.enumerated().compactMap { index, line in
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  !tokens[index].contains(where: { ($0.kind == .comment || $0.kind == .string) && $0.range.contains(match.range.location) })
            else { return nil }
            return SourceMatch(location: CodeLocation(path: path, line: index + 1, column: match.range.location + 1),
                               text: line.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Only exact paths and relative imports are resolved here. Symbol definitions belong to a language server.
    public static func resolve(_ reference: String, from path: String, root: String, paths: [String]) -> CodeLocation? {
        var location = CodeLocation.parse(reference)
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        if location.path.hasPrefix(base + "/") { location.path = String(location.path.dropFirst(base.count + 1)) }
        let neighbour = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(location.path)
        let candidates = location.path.hasPrefix(".") ? [neighbour, location.path] : [location.path, neighbour]
        let indexed = Set(paths)
        for candidate in candidates {
            let absolute = URL(fileURLWithPath: root).appendingPathComponent(candidate).standardizedFileURL.path
            guard absolute.hasPrefix(base + "/") else { continue }
            let normal = String(absolute.dropFirst(base.count + 1))
            for suffix in ["", ".ts", ".tsx", ".js", ".jsx", ".swift", ".php", ".py", "/index.ts", "/index.tsx", "/index.js", "/__init__.py"] where indexed.contains(normal + suffix) {
                location.path = normal + suffix
                return location
            }
        }
        return nil
    }
}
