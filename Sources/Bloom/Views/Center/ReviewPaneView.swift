import SwiftUI
import BloomCore

/// The review, filling one pane of the centre column: one file at a time, at the full height of
/// the window.
///
/// This is where reading a change belongs. It used to happen in a two hundred point drawer under
/// the inspector's file list, where a diff got about eight lines and editing a file got the same,
/// and the list it was under had to shrink to make room for it. In the centre both stop being a
/// trade: the list keeps the whole inspector, the file keeps the whole column, and the split
/// (Cmd+\) puts the conversation beside the diff instead of above it.
///
/// It draws no chrome of its own. `DiffView` already carries the bar that names the file and
/// holds Viewed, revert, the layout toggles and the Diff / Edit pair, and a second bar over the
/// top of it would say the same things twice.
struct ReviewPaneView: View {
    @Bindable var model: WorkspaceModel
    var tab: CenterTab

    /// The changed file this review is pointed at, if the agent did touch it. Nil is not a
    /// failure: the worktree tree opens files nobody changed, and a file can stop being changed
    /// underneath the reader when the agent reverts it.
    private var changed: ChangedFile? {
        model.changedFiles.first { $0.path == tab.path }
    }

    private var exists: Bool {
        !tab.path.isEmpty
            && FileManager.default.fileExists(
                atPath: (model.workspace.path as NSString).appendingPathComponent(tab.path)
            )
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surface)
            .background { shortcuts }
    }

    @ViewBuilder
    private var content: some View {
        if let changed {
            // Keyed on the path so walking to the next file builds a new view rather than
            // reusing this one's loaded rows, and so the header bar's Viewed toggle rebinds to
            // the new file's defaults key.
            DiffView(model: model, file: changed)
                .id(changed.path)
        } else if exists {
            FilePreview(model: model, path: tab.path)
                .id(tab.path)
        } else if tab.path.isEmpty {
            EmptyStateView(
                glyph: "doc.text",
                title: "No file open",
                message: model.changedFiles.isEmpty
                    ? "Nothing in this worktree differs from \(model.workspace.baseBranch) yet."
                    : "Pick a file in the inspector to read it here."
            )
        } else {
            // A file the agent deleted, or one that was reverted and then removed. Said plainly
            // rather than left as an empty rectangle, which reads as a failure to load.
            EmptyStateView(
                glyph: "doc.questionmark",
                title: "\((tab.path as NSString).lastPathComponent) is gone",
                message: "It is no longer in this worktree. Pick another file in the inspector."
            )
        }
    }

    /// The walk through a change, without the mouse.
    ///
    /// Hidden buttons rather than menu commands, for the reason spelled out in `SessionTabsView`:
    /// the app's menu bar is built elsewhere, and a key equivalent is only offered to the menu bar
    /// and to the view hierarchy. These are in the hierarchy, and only while a review is actually
    /// on screen, so the same keys mean nothing while the reader is in a conversation.
    ///
    /// Cmd+Option+J and K rather than Conductor's bare j and k. Bare letters are its choice
    /// because it can suppress them while an input has focus; a SwiftUI window has text fields in
    /// three columns at once and no such gate, and a review that ate every j typed into the
    /// composer would be worse than no shortcut at all.
    private var shortcuts: some View {
        ZStack {
            Button("Next Changed File") { FileReview.step(1, in: model) }
                .keyboardShortcut("j", modifiers: [.command, .option])
            Button("Previous Changed File") { FileReview.step(-1, in: model) }
                .keyboardShortcut("k", modifiers: [.command, .option])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
