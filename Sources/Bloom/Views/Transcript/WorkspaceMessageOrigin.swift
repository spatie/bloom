import SwiftUI
import BloomCore

/// The line above a message between workspaces: "From" or "To", and the workspace.
///
/// **Two words and a name, and it used to be five things.** A mark with the workspace's initial,
/// "To", the name in colour, then the project and the chat after a dot. Reported as too much, and
/// it was: the initial repeated the name's first letter, and the project and chat were there to
/// tell two workspaces of one name apart, which is a case the name resolving on click already
/// answers. What a reader wants from the line is who, in words they would say out loud.
///
/// **The name is the link.** There was an "Open" button under the bubble repeating the name a
/// second time; the name itself goes to the workspace now, and says so under the pointer by taking
/// the message colour and an underline. At rest it is the secondary ink, so the line stays a quiet
/// caption rather than a row of links over every message.
struct WorkspaceMessageOrigin: View {
    enum Direction {
        /// Above a message that arrived here.
        case from
        /// Above a message this chat sent.
        case to
    }

    var end: WorkspaceMessageEnd?
    var direction: Direction

    @Environment(AppModel.self) private var app
    @State private var isHovered = false

    private var preposition: String {
        switch direction {
        case .from: "From"
        case .to: "To"
        }
    }

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            Text(preposition).foregroundStyle(Palette.textTertiary)

            if let end, let id = end.workspaceID {
                Button { app.revealWorkspace(id) } label: {
                    Text(end.workspace)
                        .fontWeight(.semibold)
                        .underline(isHovered)
                        .foregroundStyle(isHovered ? Palette.workspaceMessage : Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .onHover { isHovered = $0 }
                .help("Go to \(end.workspace)")
            } else {
                // The owner's own client, which is standing in no workspace, so there is nowhere
                // to go. It is the owner, which is the plainest thing to call it.
                Text(end?.workspace ?? "you")
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .font(Typo.caption)
        .lineLimit(1)
        .truncationMode(.middle)
    }
}
