import UIKit
import SwiftUI
import BloomUI
import BloomClient

/// UIKit owns scrolling and reuse. Message surfaces and markdown are the Mac's shared SwiftUI components.
final class TranscriptCell: UITableViewCell {
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("Use init(style:reuseIdentifier:)") }

    func configure(kind: String, text: String, identity: String, isStreaming: Bool = false) {
        contentConfiguration = UIHostingConfiguration {
            MobileTranscriptRow(kind: kind, text: text, isStreaming: isStreaming)
                .id(identity)
                .tint(Color(uiColor: BloomTheme.accent))
        }
        .margins(.all, 0)
    }
}

private struct MobileTranscriptRow: View {
    let kind: String
    let text: String
    let isStreaming: Bool

    var body: some View {
        if kind == "user" {
            BloomUserBubble(fill: Color(uiColor: BloomTheme.colour(PaletteInk.accentFill))) {
                Text(verbatim: text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
        } else if kind == "assistant" || kind == "assistantText" {
            BloomAssistantProse {
                BloomMarkdown(text: text, isStreaming: isStreaming)
                    .font(.body)
                    .textSelection(.enabled)
            }
        } else {
            DisclosureGroup {
                Text(verbatim: text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(title, systemImage: kind == "error" ? "exclamationmark.triangle" : "terminal")
                    .font(.callout)
                    .foregroundStyle(kind == "error" ? Color.red : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private var title: String {
        let titles = ["thinking": "Thinking", "toolUse": "Tool call", "toolResult": "Tool result", "permissionAsk": "Permission request", "result": "Turn complete", "error": "Error", "system": "Session", "notice": "Notice", "crew": "Agent update"]
        return titles[kind] ?? kind
    }
}
