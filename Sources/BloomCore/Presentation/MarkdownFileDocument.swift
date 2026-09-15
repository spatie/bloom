import Foundation

/// A preview prefers unsaved text and never writes to the file or the editor's draft.
public struct MarkdownFileDocument: Sendable {
    public static let lineLimit = 5_000

    public let text: String
    public let isTruncated: Bool

    public static func read(path: String, draft: String?) throws -> Self {
        let source = try draft ?? FileEditor.read(path).text
        let lines = source.components(separatedBy: "\n")
        return Self(
            text: lines.prefix(lineLimit).joined(separator: "\n"),
            isTruncated: lines.count > lineLimit
        )
    }
}
