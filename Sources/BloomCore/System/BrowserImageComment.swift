import Foundation

/// The chip stays compact in the draft, like a diff comment. Its words and page address travel
/// with the screenshot when the message is composed, and persist with the attachment meanwhile.
public struct BrowserImageComment: Codable, Hashable, Sendable {
    public var body: String
    public var address: String

    public init(body: String, address: String) {
        self.body = body
        self.address = address
    }

    public static func expand(_ draft: String, comments: [String: BrowserImageComment]) -> String {
        AttachmentDraft.parse(draft, paths: Array(comments.keys)).segments.map { segment in
            guard case .attachment(let path) = segment, let comment = comments[path] else { return segment.text }
            return BrowserRegion.draft(comment: comment.body, address: comment.address, paths: [path])
        }.joined()
    }
}
