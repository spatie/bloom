import SwiftUI
import BatonCore

/// One workspace in the sidebar.
///
/// This exists as its own type because the leading glyph carries more weight than anything else
/// in the window: with a dozen agents running in parallel, the glyph is the only thing that says,
/// without a click, which of them is working, which needs reading and which fell over. Everything
/// else on the row is secondary and is allowed to truncate.
///
/// What the mark distinguishes is decided by `WorkspaceStatus`, not here: this file only turns a
/// verdict into a shape and a colour. The verdict spans both halves of a workspace's life, the
/// local one (setting up, running, unread, changed) and GitHub's (draft, checks, merged), because
/// a column that shows only the local half cannot answer the question the user actually has,
/// which is which of these is finished.
///
/// The row draws no background of its own. It lives in a `List` with `.listStyle(.sidebar)`, and
/// that list already draws AppKit selection: the accent colour while the window is key, a quiet
/// grey when it is not. Painting a second highlight underneath was what produced the solid dark
/// bar the owner saw.
///
/// Text uses the hierarchical styles rather than fixed label colours for the same reason: inside
/// a selected row the list inverts `.primary` and `.secondary` for us, and a pinned
/// `NSColor.labelColor` would stay dark on the accent fill.
struct WorkspaceRow: View {
    var workspace: Workspace
    /// Only used to keep the meaning colours legible against the selection fill. The highlight
    /// itself belongs to the list.
    var isSelected: Bool
    /// Whether an agent is mid turn in this workspace. Passed in rather than read here, so the row
    /// stays a pure function of its inputs.
    var isRunning: Bool
    /// The id of the row being renamed in place, shared across the whole list so only one field
    /// can ever be open.
    @Binding var renaming: String?

    @Environment(AppModel.self) private var app
    /// Selection only paints the accent colour while the window is active. Anything that inverts
    /// has to follow that, or a background window shows white marks on a grey bar.
    @Environment(\.controlActiveState) private var activeState

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { renaming == workspace.id }

    private var isEmphasized: Bool { isSelected && activeState != .inactive }

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            glyph
                .frame(width: Metrics.glyph, height: Metrics.glyph)
                // The glyph is the row's whole state in one mark, so VoiceOver has to be told
                // what it means rather than being handed an unlabelled image, and a pointer
                // resting on it gets the same sentence.
                .accessibilityLabel(statusDescription)
                .help(statusDescription)

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
            }

            Spacer(minLength: Metrics.spacingSmall)

            if !isRenaming {
                if workspace.pinned {
                    Image(systemName: "pin.fill")
                        .font(Typo.micro)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Pinned")
                }
                if workspace.hasDiff {
                    DiffStatLabel(
                        additions: workspace.additions,
                        deletions: workspace.deletions,
                        compact: true
                    )
                }
            }
        }
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

    // MARK: - Glyph

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

    /// Every state is a different shape, not only a different colour, so the column can be read
    /// at a glance and by someone who cannot tell the red one from the green one.
    private var glyphSymbol: String {
        switch status {
        case .settingUp, .running: ""
        case .setupFailed: "exclamationmark.triangle.fill"
        case .unread: "circle.fill"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .checksFailing: "xmark.circle.fill"
        case .checksRunning: "clock"
        case .checksPassed: "checkmark.circle.fill"
        case .draft, .pullRequestOpen: "arrow.triangle.pull"
        case .changed: "arrow.triangle.branch"
        case .clean: "circle.dotted"
        }
    }

    /// A selected row is filled with the accent colour, and every meaning colour in the palette is
    /// unreadable on it. On selection the shape carries the meaning alone and the mark borrows the
    /// row's own foreground, which is the same trade the diff counts make.
    private var glyphTint: AnyShapeStyle {
        if isEmphasized { return AnyShapeStyle(Palette.textInverted) }
        return switch status {
        case .setupFailed, .checksRunning: AnyShapeStyle(Palette.warning)
        case .checksFailing: AnyShapeStyle(Palette.negative)
        // Green is the palette's "this went well", and a merge landing is the best outcome a
        // workspace has, so it shares the colour with passing checks and differs in shape.
        case .checksPassed, .merged: AnyShapeStyle(Palette.positive)
        // The accent is what the app uses for "this is waiting for you" rather than for a
        // machine, which is exactly what an unread turn and an open pull request are.
        case .unread, .pullRequestOpen: AnyShapeStyle(Palette.accent)
        case .changed: AnyShapeStyle(.secondary)
        default: AnyShapeStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch status {
        case .settingUp:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
        case .running:
            ActivityDot(isActive: true, tint: isEmphasized ? Palette.textInverted : Palette.running)
        default:
            Image(systemName: glyphSymbol)
                // The unread dot is a mark rather than a symbol, so it is drawn a size down.
                .font(status == .unread ? Typo.micro : Typo.caption)
                .foregroundStyle(glyphTint)
        }
    }

    // MARK: - Renaming

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != workspace.name else { return }
        Task { await app.rename(workspace, to: name) }
    }
}
