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

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { renaming == workspace.id }

    var body: some View {
        HStack(spacing: 6) {
            glyph
                .frame(width: Self.glyphSize, height: Self.glyphSize)

            if isRenaming {
                TextField("", text: $draft)
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

            Spacer(minLength: 4)

            if !isRenaming {
                if workspace.pinned {
                    Image(systemName: "pin.fill")
                        .font(Typo.micro)
                        .foregroundStyle(.tertiary)
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
    }

    /// Matches the cap height of the surrounding text, so the glyphs line up down the column
    /// whichever state each row happens to be in.
    private static let glyphSize: CGFloat = 13

    // MARK: - Glyph

    /// The states a single glyph has to distinguish, in the order they matter to the user.
    private enum Glyph {
        case settingUp
        case running
        case failed
        case unread
        case idle
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
            ActivityDot(isActive: true, tint: isSelected ? Palette.textInverted : Palette.running)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Typo.caption)
                .foregroundStyle(Palette.warning)
        case .unread:
            // The unread marker is the accent colour, which is also the selection fill, so on a
            // selected row it has to borrow the row's own foreground to stay visible at all.
            Image(systemName: "circle.fill")
                .font(Typo.micro)
                .foregroundStyle(isSelected ? Color.primary : Palette.accent)
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
