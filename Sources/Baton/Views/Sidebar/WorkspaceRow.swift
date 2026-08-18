import SwiftUI
import BatonCore

/// One workspace in the sidebar.
///
/// This exists as its own type because the leading glyph carries more weight than anything else
/// in the window: with a dozen agents running in parallel, the glyph is the only thing that says,
/// without a click, which of them is working, which needs reading and which fell over. Everything
/// else on the row is secondary and is allowed to truncate.
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
                // what it means rather than being handed an unlabelled image.
                .accessibilityLabel(glyphState.description)

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
        // The list inverts the row's text for us, but a label that carries its own colour, such as
        // the green plus count, has to be told. This is the same signal the inspector's lists send.
        .environment(\.isOnEmphasizedSelection, isEmphasized)
    }

    // MARK: - Glyph

    /// The states a single glyph has to distinguish, in the order they matter to the user.
    private enum Glyph {
        case settingUp
        case running
        case failed
        case unread
        case idle

        var description: String {
            switch self {
            case .settingUp: "Setting up"
            case .running: "Agent running"
            case .failed: "Setup failed"
            case .unread: "Unread"
            case .idle: "Idle"
            }
        }
    }

    private var glyphState: Glyph {
        if workspace.setupState == .running { return .settingUp }
        if isRunning { return .running }
        if workspace.setupState == .failed { return .failed }
        if workspace.unread { return .unread }
        return .idle
    }

    @ViewBuilder
    private var glyph: some View {
        switch glyphState {
        case .settingUp:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
        case .running:
            ActivityDot(isActive: true, tint: isEmphasized ? Palette.textInverted : Palette.running)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Typo.caption)
                .foregroundStyle(isEmphasized ? Palette.textInverted : Palette.warning)
        case .unread:
            // The unread marker is the accent colour, which is also the selection fill, so on a
            // selected row it has to borrow the row's own foreground to stay visible at all.
            Image(systemName: "circle.fill")
                .font(Typo.micro)
                .foregroundStyle(isEmphasized ? Palette.textInverted : Palette.accent)
        case .idle:
            Image(systemName: "arrow.triangle.branch")
                .font(Typo.caption)
                .foregroundStyle(.tertiary)
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
