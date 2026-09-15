import Foundation
import BloomClient

/// MCP content stays structured in the canonical tool-result event. Only readable parts become text.
extension CodexMcpToolCall {
    var completedContent: JSONValue {
        var blocks = result?["content"]?.arrayValue ?? []
        if let text = result?["content"]?.stringValue { blocks.append(.object(["type": .string("text"), "text": .string(text)])) }
        if let structured = result?["structuredContent"], structured != .null {
            let text = Self.readableStructured(structured).prettyPrinted
            if !blocks.contains(where: { $0["text"]?.stringValue == text }) {
                blocks.append(.object(["type": .string("text"), "text": .string(text)]))
            }
        }
        if let errorMessage, !errorMessage.isEmpty, !blocks.contains(where: { $0["text"]?.stringValue == errorMessage }) {
            blocks.append(.object(["type": .string("text"), "text": .string(errorMessage)]))
        }
        return .array(blocks)
    }

    var completedText: String { ToolResultContent.render(completedContent).text }
    var completedIsError: Bool { status == .failed || status == .declined || errorMessage != nil || result?["isError"]?.boolValue == true }

    private static func readableStructured(_ value: JSONValue, depth: Int = 0) -> JSONValue {
        guard depth < 64 else { return .string("[nested data omitted]") }
        switch value {
        case .array(let values): return .array(values.map { readableStructured($0, depth: depth + 1) })
        case .object(let values):
            let binary = ["image", "audio", "base64"].contains(values["type"]?.stringValue ?? "")
            var rendered: [String: JSONValue] = [:]
            for (key, value) in values {
                if (key == "data" && binary) || (key == "blob" && values["mimeType"] != nil) {
                    rendered[key] = .string("[binary data omitted]")
                } else { rendered[key] = readableStructured(value, depth: depth + 1) }
            }
            return .object(rendered)
        default: return value
        }
    }
}
