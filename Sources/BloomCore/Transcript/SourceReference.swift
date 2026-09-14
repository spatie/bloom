import Foundation

/// Internal source links never pass through NSWorkspace, even when the reference names an app bundle.
public enum SourceReference {
    public static func url(_ reference: String) -> URL? {
        var reference = reference
        if reference.hasPrefix("file://"), let file = URL(string: reference), file.isFileURL {
            reference = file.path + (file.fragment.map { "#\($0)" } ?? "")
        }
        guard !reference.contains("://"), !reference.hasPrefix("mailto:"), !reference.contains("\n") else { return nil }
        let location = CodeLocation.parse(reference)
        guard location.path.range(of: #"^[\p{L}\p{N}_./ ~-]+$"#, options: .regularExpression) != nil else { return nil }
        let filename = (location.path as NSString).lastPathComponent
        guard filename.contains("."), filename.contains(where: { $0.isLetter }),
              !location.path.contains(":"), !location.path.contains("#") else { return nil }
        var components = URLComponents()
        components.scheme = "bloom-source"
        components.host = "file"
        components.queryItems = [URLQueryItem(name: "path", value: location.path),
                                URLQueryItem(name: "line", value: String(location.line)),
                                URLQueryItem(name: "column", value: String(location.column))]
        return components.url
    }

    public static func location(_ url: URL) -> CodeLocation? {
        guard url.scheme == "bloom-source", url.host == "file",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value, !path.isEmpty else { return nil }
        return CodeLocation(path: path, line: Int(items.first(where: { $0.name == "line" })?.value ?? "") ?? 1,
                              column: Int(items.first(where: { $0.name == "column" })?.value ?? "") ?? 1)
    }

    public static func links(in text: String) -> [(NSRange, URL)] {
        let pattern = #"(?<![\w@:/])(?:[\w./-]+\.[\w]+)(?::\d+(?::\d+)?|#L\d+(?:-L?\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = url((text as NSString).substring(with: match.range)) else { return nil }
            return (match.range, url)
        }
    }
}
