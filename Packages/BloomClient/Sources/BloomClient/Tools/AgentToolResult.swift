import Foundation

public struct AgentToolResult: Sendable, Hashable {
    public let toolUseID: String
    public let text: String
    public let isError: Bool
    /// Set when the call never ran. `is_error` is true for a refusal as well as for a failure, so
    /// this is what separates the two. See `ToolRefusal`.
    public let refusal: ToolRefusal?
    /// Screenshots come back as image blocks. The bytes are not lifted out, only the fact that
    /// they were there, so a row can offer to pull them from the raw payload.
    public let hasImages: Bool
    public let raw: Data
    public let parentToolUseID: String?
    public let uuid: String?
    public let sessionID: String?

    public init(
        toolUseID: String,
        text: String,
        isError: Bool = false,
        refusal: ToolRefusal? = nil,
        hasImages: Bool = false,
        raw: Data = Data(),
        parentToolUseID: String? = nil,
        uuid: String? = nil,
        sessionID: String? = nil
    ) {
        self.toolUseID = toolUseID
        self.text = text
        self.isError = isError
        self.refusal = refusal
        self.hasImages = hasImages
        self.raw = raw
        self.parentToolUseID = parentToolUseID
        self.uuid = uuid
        self.sessionID = sessionID
    }
}
