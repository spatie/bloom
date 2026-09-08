import SwiftUI
import BloomCore

/// Remote content is rendered as text. Desktop transcript rows can open local attachments and
/// files, which would resolve a server path against the wrong machine in this window.
struct ServerMessageView: View {
    var message: Message

    var body: some View {
        Group {
            if message.kind == .user {
                VStack(alignment: .leading, spacing: 4) {
                    Text("You").font(.caption).foregroundStyle(.secondary)
                    Text(UserTurnPrompt.text(in: message.payload))
                }
            } else if let event = AgentEvent.decode(line: String(decoding: message.payload, as: UTF8.self)) {
                content(event)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func content(_ event: AgentEvent) -> some View {
        switch event {
        case .assistantText(let block): Text(block.text)
        case .thinking(let block):
            DisclosureGroup("Thinking") { Text(block.text).foregroundStyle(.secondary) }
        case .toolUse(let tool):
            DisclosureGroup(tool.name) { Text(tool.input.prettyPrinted).font(.system(.caption, design: .monospaced)) }
        case .toolResult(let result):
            DisclosureGroup(result.isError ? "Tool failed" : "Tool result") {
                Text(String(decoding: result.raw, as: UTF8.self)).font(.system(.caption, design: .monospaced))
            }
        case .error(let error): Text(error.message).foregroundStyle(.red)
        case .result(let result):
            Text(result.isError ? "Turn ended with an error" : "Turn finished").font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
}
