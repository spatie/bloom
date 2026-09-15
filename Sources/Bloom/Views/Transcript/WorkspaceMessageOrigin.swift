import SwiftUI
import BloomCore

/// The line above a message between workspaces: which workspace, in which project, which chat.
///
/// A small mark with the workspace's initial, then its name in the colour every such message is
/// drawn in, then the project and chat in the quiet ink. The name is the part a reader looks for,
/// so it is the part that is coloured; the rest is there to tell two workspaces of one name apart.
struct WorkspaceMessageOrigin: View {
    enum Direction {
        /// Above a message that arrived here.
        case from
        /// Above a message this chat sent.
        case to
    }

    var end: WorkspaceMessageEnd?
    var direction: Direction

    private var resolved: WorkspaceMessageEnd { end ?? .ownerClient }

    private var detail: String {
        [resolved.project, resolved.chat].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            Text(String(resolved.workspace.prefix(1)).uppercased())
                .font(Typo.micro)
                .fontWeight(.bold)
                .foregroundStyle(Palette.windowBackground)
                .frame(width: 16, height: 16)
                .background(Palette.workspaceMessage, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)

            if direction == .to {
                Text("To").foregroundStyle(Palette.textTertiary)
            }
            Text(resolved.workspace)
                .fontWeight(.semibold)
                .foregroundStyle(Palette.workspaceMessage)
            if !detail.isEmpty {
                Text("· \(detail)").foregroundStyle(Palette.textTertiary)
            }
        }
        .font(Typo.caption)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .combine)
    }
}
