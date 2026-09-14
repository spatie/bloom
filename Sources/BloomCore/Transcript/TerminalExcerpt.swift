import Foundation

/// A selection is copied now, not looked up in a terminal whose scrollback can change or vanish.
public struct TerminalExcerpt: Codable, Sendable, Hashable {
    public var terminalID: TerminalTabID
    public var workspaceID: WorkspaceID
    public var label: String
    public var firstLine: Int
    public var lastLine: Int
    public var text: String
    public var capturedAt: Date

    public init?(
        terminalID: TerminalTabID, workspaceID: WorkspaceID, label: String,
        firstLine: Int, lastLine: Int, text: String, capturedAt: Date = Date()
    ) {
        guard text.contains(where: { !$0.isWhitespace }) else { return nil }
        self.terminalID = terminalID
        self.workspaceID = workspaceID
        self.label = label
        self.firstLine = max(1, min(firstLine, lastLine))
        self.lastLine = max(self.firstLine, max(firstLine, lastLine))
        self.text = text
        self.capturedAt = capturedAt
    }

    /// JSON avoids ambiguous fences when a log itself contains Markdown or control sequences.
    /// The attachment remains both machine-readable and independently recoverable from disk.
    public func attachmentText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public var filename: String { "terminal-excerpt.json" }
}
