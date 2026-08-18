import SwiftUI
import BloomCore

/// One workspace in the sidebar.
///
/// This exists as its own type because the leading glyph carries more weight than anything else
/// in the window: with a dozen agents running in parallel, the glyph is the only thing that says,
/// without a click, which of them is working, which needs reading and which fell over. Everything
/// else on the row is secondary and is allowed to truncate.
///
/// What the mark distinguishes is decided by `WorkspaceStatus`, not here, and how it is drawn by
/// `WorkspaceStatusGlyph`, which the legend shares so the two cannot describe different marks. The
/// verdict spans both halves of a workspace's life, the local one (setting up, running, unread,
/// changed) and GitHub's (draft, checks, merged), because a column that shows only the local half
/// cannot answer the question the user actually has, which is which of these is finished.
///
/// The row is a `Label`, not an `HStack` with a glyph in front of the name. That is what puts the
/// mark in the same icon column the list gives Home and Search, so one text column runs down the
/// whole source list instead of the three it had: the hand-built stack started its text 12 points
/// left of the rows above it.
///
/// The row draws no background of its own. It lives in a `List` with `.listStyle(.sidebar)`, and
/// that list already draws AppKit selection: the accent colour while the list has the keyboard, a
/// quiet grey when it does not. Painting a second highlight underneath was what produced the solid
/// dark bar the owner saw.
///
/// Text uses the hierarchical styles rather than fixed label colours for the same reason: inside
/// a selected row the list inverts `.primary` and `.secondary` for us, and a pinned
/// `NSColor.labelColor` would stay dark on the accent fill.
struct WorkspaceRow: View {
    var workspace: Workspace
    /// Whether an agent is mid turn in this workspace. Passed in rather than read here, so the row
    /// stays a pure function of its inputs.
    var isRunning: Bool
    /// The id of the row being renamed in place, shared across the whole list so only one field
    /// can ever be open.
    @Binding var renaming: String?

    @Environment(AppModel.self) private var app
    /// Whether this row is the one the list is painting with the accent colour.
    ///
    /// This is the list's own answer, not one derived from the window's active state. AppKit fills
    /// a selected row with the accent only while the list itself holds the keyboard, so a row that
    /// inverted whenever the window was merely key drew white counts on the grey unfocused bar
    /// every time focus was in the composer or a terminal.
    @Environment(\.backgroundProminence) private var backgroundProminence

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { renaming == workspace.id }

    private var isEmphasized: Bool { backgroundProminence == .increased }

    var body: some View {
        Label {
            HStack(spacing: Metrics.spacing) {
                if isRenaming {
                    TextField("Workspace name", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit { commit() }
                        .onExitCommand { renaming = nil }
                        .task {
                            draft = workspace.name
                            // A beat, so the field exists before focus moves to it.
                            try? await Task.sleep(for: .milliseconds(30))
                            fieldFocused = true
                        }
                } else {
                    Text(workspace.name)
                        .fontWeight(workspace.unread ? .medium : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: Metrics.spacingSmall)

                    if workspace.pinned {
                        Image(systemName: "pin.fill")
                            .font(Typo.micro)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Pinned")
                    }
                    if workspace.hasDiff {
                        SidebarDiffStat(
                            additions: workspace.additions,
                            deletions: workspace.deletions
                        )
                    }
                }
            }
        } icon: {
            WorkspaceStatusGlyph(status: status, isOnSelection: isEmphasized)
        }
        // The glyph is the row's whole state in one mark, so VoiceOver has to be told what it
        // means rather than being handed an unlabelled image, and a pointer resting on it gets the
        // same sentence. Both sit on the row: the icon of a `Label` is not a hit target of its own.
        .accessibilityValue(statusDescription)
        .help(statusDescription)
        .contentShape(Rectangle())
        // Only rows that exist ask GitHub anything, and the id carries the branch and whether
        // there is any work at all, because both change what is worth asking about.
        .task(id: "\(workspace.id)|\(workspace.branch)|\(workspace.hasDiff)") {
            await WorkspacePullRequests.shared.track(workspace)
        }
        // The list inverts the row's text for us, but a label that carries its own colour, such as
        // the green plus count, has to be told. This is the same signal the inspector's lists send.
        .environment(\.isOnEmphasizedSelection, isEmphasized)
    }

    // MARK: - Status

    /// GitHub's answer for this branch, if anything has asked yet. Read straight from the shared
    /// store rather than passed in, because the sidebar's row builder has no way to reach it.
    private var pullRequest: PullRequest? {
        WorkspacePullRequests.shared.pullRequest(for: workspace.id)
    }

    private var status: WorkspaceStatus {
        WorkspaceStatus.resolve(
            workspace: workspace, isRunning: isRunning, pullRequest: pullRequest
        )
    }

    /// What the mark means, in one sentence, for the tooltip and for VoiceOver. Both get the same
    /// words on purpose: a sighted user hovering and a VoiceOver user landing on the row are
    /// asking the identical question.
    private var statusDescription: String {
        status.summary(pullRequest: pullRequest)
    }

    // MARK: - Renaming

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != workspace.name else { return }
        Task { await app.rename(workspace, to: name) }
    }
}
