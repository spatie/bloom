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

    /// Whether the file is still on disk. Resolved when the path or the changes poll moves, and
    /// never from `body`: this was a computed property calling `FileManager.fileExists`, and
    /// `body` runs on every frame of a window resize because `.onGeometryChange` writes
    /// `paneHeight` as the pane grows. That is a `stat` per frame, on the main thread, for the
    /// whole of a drag.
    ///
    /// Nil until the first answer arrives, and read as "assume it is there", so opening a file
    /// draws it on the frame it was clicked rather than flashing the sentence that says it is
    /// gone. A file that really has gone says so a frame later.
    @State private var exists: Bool?

    private var isPresent: Bool { exists ?? true }

    private struct ExistsID: Hashable {
        var path: String
        var generation: Int
    }

    /// How tall the whole pane is, which caps how far the composer's divider can be dragged.
    ///
    /// In the composer's own object rather than in this view's state, and quantised on the way in,
    /// for the reason `ComposerRoom` sets out: as state it re-ran this body, and with it the diff
    /// beside the box, every time the draft rewrapped a line.
    @State private var room = ComposerRoom()

    /// The conversation's text size, face and line height, applied to the composer here exactly
    /// as `ChatPaneView` applies them to its whole subtree. Without this the same composer would
    /// change as the reader moved between the conversation and the review, which reads as a bug
    /// rather than a setting.
    @AppStorage(ChatTextSize.defaultsKey) private var textSize = ChatTextSize.standard
    @AppStorage(ChatFont.defaultsKey) private var chatFont = ChatFont.standard
    @AppStorage(ChatLineHeight.defaultsKey) private var lineHeight = ChatLineHeight.standard

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // The same composer the conversation shows, bound to the same transcript, so the
            // chips a review has accumulated are visible from the diff they were written on and
            // Return sends from here. It used to live only in the chat pane, which meant placing
            // comments on this screen and then leaving it to send them. A second composer view
            // was considered and rejected: one draft, one send path, nothing to keep in step.
            if let transcript = composerTranscript {
                ComposerView(transcript: transcript, model: model, room: room)
                    .environment(\.fontScale, textSize.scale)
                    .environment(\.chatFont, chatFont)
                    .environment(\.chatLineHeight, lineHeight)
            }
        }
        .onGeometryChange(for: CGFloat.self) { PaneMeasure.room($0.size.height) } action: {
            room.height = $0
        }
        .background(Palette.surface)
        // A pane can be pointed at a session this launch has never opened, so the transcript is
        // built here rather than assumed, exactly as `CenterPaneView.prepare` does for a chat.
        .task(id: model.activeSession?.id) {
            guard let session = model.activeSession else { return }
            model.prepareTranscript(for: session.id)
        }
        // Keyed on the poll as well as the path, because a file can be deleted underneath a reader
        // who has not moved: the changes generation is what says the worktree has been looked at
        // again.
        .task(id: ExistsID(path: tab.path, generation: model.changesGeneration)) {
            let path = tab.path
            let absolute = (model.workspace.path as NSString).appendingPathComponent(path)
            exists = await Task.detached(priority: .userInitiated) {
                !path.isEmpty && FileManager.default.fileExists(atPath: absolute)
            }.value
        }
    }

    /// The conversation a turn sent from here joins: the active session's, which already falls
    /// back to the first. Nil only when the workspace has no session at all, and then there is
    /// nothing to send to and no composer is drawn.
    private var composerTranscript: TranscriptModel? {
        model.activeSession.flatMap { model.existingTranscript(for: $0.id) }
    }

    @ViewBuilder
    private var content: some View {
        if let changed {
            // Keyed on the path so walking to the next file builds a new view rather than
            // reusing this one's loaded rows, and so the header bar's Viewed toggle rebinds to
            // the new file's defaults key.
            DiffView(model: model, file: changed)
                .id(changed.path)
        } else if tab.path.isEmpty {
            // Asked before the two branches below, because with no path there is nothing to look
            // for and `isPresent` answers optimistically until the first look comes back.
            EmptyStateView(
                glyph: "doc.text",
                title: "No file open",
                message: model.changedFiles.isEmpty
                    ? "Nothing in this worktree differs from \(model.workspace.baseBranch) yet."
                    : "Pick a file in the inspector to read it here."
            )
        } else if isPresent, FileMediaView.isMedia(path: tab.path) {
            // An image, a PDF, a video. `FilePreview` reads a file as text and would say there is
            // nothing to show, which for the screenshot somebody just attached is both wrong and
            // the whole reason they clicked.
            FileMediaView(worktree: model.workspace.path, path: tab.path)
                .id(tab.path)
        } else if isPresent {
            FilePreview(model: model, path: tab.path)
                .id(tab.path)
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

}
