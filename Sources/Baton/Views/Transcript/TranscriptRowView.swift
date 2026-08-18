import SwiftUI
import BatonCore

/// One stored event, rendered.
///
/// The row decodes its own payload, and it does it here rather than up front. A session can hold
/// tens of thousands of rows and the enclosing `LazyVStack` only ever builds the handful on screen,
/// so decoding here is the difference between opening a long transcript instantly and parsing forty
/// megabytes of JSON before the first frame. Every decode goes through `TranscriptEventCache`, so a
/// row that is rebuilt on every streamed token still only parses once.
///
/// This view decides which kind of row it is and hands the decoded payload to the view that draws
/// it. Every kind except assistant prose, a user turn and an expanded row is exactly one line tall.
/// That is the whole design: an agent run reads as a list of actions, not a chat log.
struct TranscriptRowView: View {
    var row: TranscriptRow
    var isExpanded = false
    var isNested = false
    /// The width a user bubble is allowed to fill, handed down because the enclosing scroll view
    /// already measured it and a per row measurement would not size to its content.
    var maxBubbleWidth: CGFloat = 560
    var onToggle: () -> Void = {}

    var body: some View {
        content
            .padding(.leading, isNested ? TranscriptLayout.nestIndent : 0)
            .overlay(alignment: .leading) {
                if isNested {
                    Rectangle()
                        .fill(Palette.border)
                        .frame(width: Metrics.hairline)
                        .padding(.leading, TranscriptLayout.inset)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .user:
            UserTurnRowView(text: userText, maxWidth: maxBubbleWidth)

        case .assistantText:
            if let text = assistantText, !text.isEmpty {
                ProseRowView(text: text)
            }

        case .thinking:
            if let text = thinkingText, !text.isEmpty {
                ThinkingRowView(text: text, isExpanded: isExpanded, onToggle: onToggle)
            }

        case .toolUse:
            if let use = toolUse {
                ToolRowView(
                    use: use,
                    result: toolResult,
                    isError: row.isError,
                    durationMS: row.durationMS,
                    isExpanded: isExpanded,
                    onToggle: onToggle
                )
            }

        case .toolResult:
            if let result = orphanResult {
                OrphanResultRowView(result: result)
            }

        case .error:
            AgentErrorRowView(
                stderr: json?["stderr"]?.stringValue ?? "",
                status: json?["status"]?.intValue,
                isExpanded: isExpanded,
                onToggle: onToggle
            )

        case .notice:
            RateLimitRowView(
                utilization: json?["rate_limit_info"]?["utilization"]?.doubleValue ?? 0,
                window: json?["rate_limit_info"]?["rateLimitType"]?.stringValue ?? ""
            )

        case .system:
            if let info = initInfo {
                SessionStartRowView(info: info)
            }

        // A result row is a turn boundary, and the footer that renders it needs the rows around it,
        // so TranscriptView draws that one itself.
        case .result:
            EmptyView()
        }
    }

    // MARK: Decoding

    private var event: AgentEvent? {
        TranscriptEventCache.event(rowID: row.id, payload: row.payload)
    }

    private var json: JSONValue? {
        TranscriptEventCache.json(rowID: row.id, payload: row.payload)
    }

    private var assistantText: String? {
        guard case .assistantText(let block)? = event else { return nil }
        return block.text
    }

    private var thinkingText: String? {
        guard case .thinking(let block)? = event else { return nil }
        return block.text
    }

    private var toolUse: AgentToolUse? {
        guard case .toolUse(let use)? = event else { return nil }
        return use
    }

    /// A tool result whose call never made it into the transcript. Rare, but it must not vanish.
    private var orphanResult: AgentToolResult? {
        guard case .toolResult(let result)? = event else { return nil }
        return result
    }

    private var initInfo: AgentInit? {
        guard case .initialized(let info)? = event else { return nil }
        return info
    }

    /// Only decoded once a row is open, because a tool result is the largest payload in the file.
    private var toolResult: AgentToolResult? {
        guard isExpanded, let payload = row.resultPayload,
              case .toolResult(let result)? = TranscriptEventCache.event(rowID: row.id, payload: payload)
        else { return nil }
        return result
    }

    /// A user turn is the line Baton itself wrote to stdin, so it is read straight out of the
    /// stored request rather than through the event decoder, which only knows about tool results.
    private var userText: String {
        guard let blocks = json?["message"]?["content"]?.arrayValue else { return "" }
        return blocks
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n")
    }
}
