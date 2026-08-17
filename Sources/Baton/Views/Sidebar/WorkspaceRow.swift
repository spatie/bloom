import SwiftUI
import BatonCore

/// One workspace in the sidebar.
///
/// This exists as its own type because the leading glyph carries more weight than anything else
/// in the window: with a dozen agents running in parallel, the glyph is the only thing that says,
/// without a click, which of them is working, which needs reading and which fell over. Everything
/// else on the row is secondary and is allowed to truncate.
///
/// The row owns no hover state. The parent list holds a single `hovered` id, because one piece of
/// state for a hundred rows is cheaper than a hundred pieces of state, and it makes "only one row
/// can be hovered" true by construction.
struct WorkspaceRow: View {
    var workspace: Workspace
    var isSelected: Bool
    var isHovered: Bool
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
                .frame(width: 13, height: 13)

            if isRenaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
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
                    .font(workspace.unread ? Typo.bodyEmphasis : Typo.body)
                    .foregroundStyle(nameTint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if !isRenaming {
                if workspace.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Palette.textTertiary)
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
        .padding(.horizontal, 6)
        .frame(height: Metrics.rowHeight)
        .rowBackground(isSelected: isSelected, isHovered: isHovered)
        .contentShape(Rectangle())
    }

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
                .controlSize(.small)
                .scaleEffect(0.5)
        case .running:
            ActivityDot(isActive: true, tint: Palette.running)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Palette.warning)
        case .unread:
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(Palette.accent)
        case .idle:
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Palette.textSecondary : Palette.textTertiary)
        }
    }

    private var nameTint: Color {
        if isSelected || workspace.unread { return Palette.textPrimary }
        return Palette.textSecondary
    }

    // MARK: - Renaming

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != workspace.name else { return }
        Task { await app.rename(workspace, to: name) }
    }
}
