import Foundation

public enum ToolResultContent {
    public static func render(_ content: JSONValue?) -> (text: String, hasImages: Bool) {
        guard let content else { return ("", false) }
        if let string = content.stringValue { return (string, false) }
        guard let blocks = content.arrayValue else { return (content.prettyPrinted, false) }

        var parts: [String] = []
        var hasImages = false
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text": parts.append(block["text"]?.stringValue ?? "")
            case "image": hasImages = true
            case "resource":
                if let text = block["resource"]?["text"]?.stringValue { parts.append(text) }
                if block["resource"]?["mimeType"]?.stringValue?.hasPrefix("image/") == true { hasImages = true }
            default: break
            }
        }
        return (parts.joined(separator: "\n"), hasImages)
    }
}
