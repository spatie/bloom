import Foundation

public struct AgentToolUse: Sendable, Hashable {
    public let id: String
    public let name: String
    public let input: JSONValue
    public let parentToolUseID: String?
    public let raw: Data
    public let messageID: String
    public let uuid: String?
    public let sessionID: String?

    public init(
        id: String,
        name: String,
        input: JSONValue,
        parentToolUseID: String? = nil,
        raw: Data = Data(),
        messageID: String = "",
        uuid: String? = nil,
        sessionID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.parentToolUseID = parentToolUseID
        self.raw = raw
        self.messageID = messageID
        self.uuid = uuid
        self.sessionID = sessionID
    }

    /// The one input field worth putting in a collapsed row header for the file tools.
    public var filePath: String? { input["file_path"]?.stringValue }
}
