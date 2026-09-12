import Foundation

/// Structured inspection of the same persisted blocks used by the Mac transcript.
public struct RemoteToolInspection: Equatable, Sendable {
    public let presentation: ToolPresentation
    public let arguments: String?
    public let output: String?
    public let status: String
    public let isError: Bool
    public let hasImages: Bool
    public let durationMS: Int?

    public init?(row: RemoteTranscriptRow) {
        self.init(message: row.message, result: row.toolResult)
    }

    public init?(message: RemoteMessage, result: RemoteMessage? = nil) {
        guard message.kind == "toolUse" || message.kind == "toolResult",
              let object = JSONValue.parse(message.payload),
              let blocks = object["message"]?["content"]?.arrayValue else { return nil }
        let type = message.kind == "toolUse" ? "tool_use" : "tool_result"
        let candidates = blocks.filter { $0["type"]?.stringValue == type }
        let key = type == "tool_use" ? "id" : "tool_use_id"
        let selected = message.refID.flatMap { id in candidates.first { $0[key]?.stringValue == id } }
            ?? (candidates.count == 1 ? candidates.first : nil)
        guard let block = selected else { return nil }
        if type == "tool_use" {
            let call = ToolCallPayload(block: block)
            presentation = ToolPresenter.present(name: call.name, input: call.input)
            arguments = call.input.prettyPrinted
            if let result, result.kind == "toolResult", let refID = message.refID, result.refID == refID {
                let completed = RemoteToolInspection(message: result)
                let summary = ToolResultSummary.decode(result.payload, toolUseID: refID)
                output = completed?.output ?? result.text
                status = completed?.status ?? (summary.isError ? "Failed" : "Completed")
                isError = completed?.isError ?? summary.isError
                hasImages = completed?.hasImages ?? false
                durationMS = result.durationMS ?? message.durationMS
            } else {
                output = nil; status = "Tool call"; isError = false; hasImages = false
                durationMS = message.durationMS
            }
        } else {
            durationMS = message.durationMS
            let rendered = ToolResultContent.render(block["content"])
            let summary = ToolResultSummary.decode(message.payload, toolUseID: block["tool_use_id"]?.stringValue)
            let failure = summary.isError && summary.refusal == nil
            presentation = ToolPresentation(glyph: failure ? "exclamationmark.triangle" : "checkmark.circle",
                                            label: summary.refusal?.label.capitalized ?? (failure ? "Tool failed" : "Tool result"),
                                            detail: ToolPresenter.firstLine(rendered.text), tint: failure ? .negative : (summary.refusal == nil ? .neutral : .warning))
            arguments = nil; output = rendered.text; status = summary.refusal?.summary ?? (failure ? "Failed" : "Completed")
            isError = failure; hasImages = rendered.hasImages
        }
    }
}
