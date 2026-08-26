import SwiftUI
import BloomCore

/// One conversation in the tab strip.
///
/// The chrome is `TabItemView`, shared with the terminal and browser tabs beside it and with the
/// bottom panel's strip, so all of them are the same height with the same close affordance and the
/// same selected treatment.
/// What is left here is only what a `Session` means: an untitled session still needs a name on
/// screen, and that placeholder must not end up in the rename field as if the user had typed it.
struct SessionTabView: View {
    var session: Session
    /// Which agent runs this chat, present only when the workspace holds more than one. See
    /// `PaneGlyph`: a strip of five Claude Code chats stays unmarked, because a mark that is on
    /// every tab tells you nothing, and those tabs wear the chat glyph instead.
    var agentGlyph: String?
    var isActive: Bool
    var isRunning: Bool
    /// Whether this is the tab the pane's leading edge runs through. See `TabItemView`.
    var isAtPaneEdge: Bool
    var isRenaming: Bool
    var canClose: Bool
    var onSelect: @MainActor () -> Void
    var onStartRename: @MainActor () -> Void
    var onCommitRename: @MainActor (String) -> Void
    var onCancelRename: @MainActor () -> Void
    var onClose: @MainActor () -> Void
    /// Absent when this tab cannot be opened beside the one the user is in. See `TabItemView`,
    /// which drops the pair of items rather than showing them greyed.
    var onSplitRight: (@MainActor () -> Void)?
    var onSplitDown: (@MainActor () -> Void)?
    var namespace: Namespace.ID

    var body: some View {
        TabItemView(
            title: session.title.isEmpty ? PaneNaming.untitledChat : session.title,
            icon: .symbol(PaneGlyph.chatTab(agentMark: agentGlyph)),
            isActive: isActive,
            isRunning: isRunning,
            isAtPaneEdge: isAtPaneEdge,
            surface: TabPane.content.surface,
            isRenaming: isRenaming,
            editableTitle: session.title,
            canClose: canClose,
            closeTitle: "Close session",
            onSelect: onSelect,
            onStartRename: onStartRename,
            onCommitRename: onCommitRename,
            onCancelRename: onCancelRename,
            onClose: onClose,
            onSplitRight: onSplitRight,
            onSplitDown: onSplitDown,
            namespace: namespace
        )
    }
}
