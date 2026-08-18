import SwiftUI
import BatonCore

/// One conversation in the tab strip.
///
/// The chrome is `CenterTabView`, shared with the terminal and browser tabs beside it, so all
/// three are the same height with the same close affordance and the same selected treatment.
/// What is left here is only what a `Session` means: an untitled session still needs a name on
/// screen, and that placeholder must not end up in the rename field as if the user had typed it.
struct SessionTabView: View {
    var session: Session
    var isActive: Bool
    var isRunning: Bool
    var isRenaming: Bool
    var canClose: Bool
    var onSelect: @MainActor () -> Void
    var onStartRename: @MainActor () -> Void
    var onCommitRename: @MainActor (String) -> Void
    var onCancelRename: @MainActor () -> Void
    var onClose: @MainActor () -> Void

    var body: some View {
        CenterTabView(
            title: session.title.isEmpty ? "Untitled" : session.title,
            icon: nil,
            isActive: isActive,
            isRunning: isRunning,
            isRenaming: isRenaming,
            editableTitle: session.title,
            canClose: canClose,
            closeTitle: "Close session",
            onSelect: onSelect,
            onStartRename: onStartRename,
            onCommitRename: onCommitRename,
            onCancelRename: onCancelRename,
            onClose: onClose
        )
    }
}
