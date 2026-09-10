import Foundation

/// The tool-use block is shared by Claude events and Bloom's translated Codex events.
public struct ToolCallPayload: Equatable, Sendable {
    public let id: String
    public let name: String
    public let input: JSONValue
    public init(block: JSONValue) {
        id = block["id"]?.stringValue ?? ""
        name = block["name"]?.stringValue ?? ""
        input = block["input"] ?? .object([:])
    }
}
