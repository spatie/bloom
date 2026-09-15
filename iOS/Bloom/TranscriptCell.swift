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

    func configure(message: RemoteMessage) {
        configure(row: RemoteTranscriptRow(message: message))
    }

    func configure(row: RemoteTranscriptRow) {
        let inspection = RemoteToolInspection(row: row)
        // Unrecognised tool payloads retain both raw sides for inspection instead of losing the result.
        let text = inspection == nil ? ([row.message.text] + (row.toolResult.map { ["Result:\n" + $0.text] } ?? [])).joined(separator: "\n\n") : ""
        configure(kind: row.message.kind, text: text, identity: String(row.id), inspection: inspection)
    }

    func configure(kind: String, text: String, identity: String, isStreaming: Bool = false, inspection: RemoteToolInspection? = nil) {
        accessoryView = nil
        let isTablet = traitCollection.userInterfaceIdiom == .pad
        contentConfiguration = UIHostingConfiguration {
            MobileTranscriptRow(kind: kind, text: text, isStreaming: isStreaming, inspection: inspection, isTablet: isTablet)
                .id(identity)
                .tint(Color(uiColor: BloomTheme.accent))
        }
        .margins(.all, 0)
        .minSize(width: 0, height: 0)
    }

    func configureQueued(_ prompt: RemoteQueuedPrompt, isCancelling: Bool, canCancel: Bool, cancel: @escaping () -> Void) {
        let isTablet = traitCollection.userInterfaceIdiom == .pad
        contentConfiguration = UIHostingConfiguration {
            BloomUserBubble(fill: Color(uiColor: BloomTheme.colour(PaletteInk.accentFill))) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: prompt.text).font(isTablet ? .subheadline : .body).foregroundStyle(.white).textSelection(.enabled)
                    Label(isCancelling ? "Removing from queue…" : "Queued", systemImage: "clock")
                        .font(.caption).foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.vertical, isTablet ? 2 : 4)
            .id("queued-" + prompt.id.rawValue)
        }.margins(.all, 0).minSize(width: 0, height: 44)
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark.circle"), for: .normal)
        button.frame.size = CGSize(width: 44, height: 44)
        button.accessibilityLabel = "Remove queued message"
        button.isEnabled = canCancel && !isCancelling
        button.addAction(UIAction { _ in cancel() }, for: .touchUpInside)
        accessoryView = button
    }

}

private struct MobileTranscriptRow: View {
    let kind: String
    let text: String
    let isStreaming: Bool
    let inspection: RemoteToolInspection?
    let isTablet: Bool
    private var textStyle: Font.TextStyle { isTablet ? .subheadline : .body }

    var body: some View {
        if let inspection {
            BloomToolCard(inspection: inspection)
        } else if kind == "user" {
            BloomUserBubble(fill: Color(uiColor: BloomTheme.colour(PaletteInk.accentFill))) {
                Text(verbatim: text)
                    .font(.system(textStyle))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, isTablet ? 2 : 4)
        } else if kind == "assistant" || kind == "assistantText" {
            BloomAssistantProse(maxWidth: isTablet ? 960 : 820, verticalInset: isTablet ? 2 : 4, showsSeparator: false) {
                BloomMarkdown(text: text, isStreaming: isStreaming, textStyle: textStyle)
                    .font(.system(textStyle))
                    .textSelection(.enabled)
            }
        } else {
            DisclosureGroup {
                Text(verbatim: text)
                    .font(.system(isTablet ? .subheadline : .callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: symbol)
                        .font(kind == "result" ? .footnote : .callout)
                        .foregroundStyle(kind == "error" ? Color.red : Color(uiColor: UIColor.secondaryLabel))
                    if kind == "error", !text.isEmpty {
                        Text(verbatim: text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(minHeight: 44, alignment: .leading)
            }
            .disclosureGroupStyle(MobileActivityDisclosureStyle())
            .padding(.horizontal, 6)
            .padding(.vertical, kind == "error" ? 4 : 0)
        }
    }

    private var title: String {
        let titles = ["thinking": "Thinking", "toolUse": "Tool activity", "toolResult": "Tool result", "permissionAsk": "Permission request", "result": "Completed", "error": "Something went wrong", "system": "Conversation", "notice": "Notice", "crew": "Agent update"]
        return titles[kind] ?? "Activity"
    }

    private var symbol: String {
        switch kind {
        case "error": "exclamationmark.triangle"
        case "result": "checkmark.circle"
        case "thinking": "ellipsis"
        case "permissionAsk": "hand.raised"
        case "system", "notice": "info.circle"
        default: "terminal"
        }
    }
}

/// Activity details stay beside their label instead of becoming another full-width navigation row.
private struct MobileActivityDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    configuration.label
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(uiColor: UIColor.secondaryLabel))
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content
                    .padding(.bottom, 8)
            }
        }
    }
}
