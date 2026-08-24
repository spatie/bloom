import SwiftUI
import BloomCore

/// Every state a pending review comment can be in on one page: at rest, under the pointer, being
/// rewritten, and after the rewrite, with the box that writes a new one underneath.
///
/// It exists because the band is four states and a diff shows one of them at a time. Judging
/// whether the edit control is quiet enough at rest and plain enough under the pointer means
/// seeing the two next to each other, in both appearances, and no screen in the app puts them
/// there.
///
/// The multi-line cases are the ones worth the page. Shift+Return grows the box, and a box that
/// grows is a claim about what the buttons under it do: they have to stay put and stay reachable
/// rather than being pushed out of the band.
///
/// Captured as a real window, light and dark:
/// `Bloom --snapshot-gallery <dir> --gallery review-comments`. Not by `--snapshot`, which renders
/// offscreen and paints a yellow placeholder over the one control this page is about.
struct ReviewCommentSnapshotGallery: View {
    /// The width a diff sheet is drawn at in a comfortable inspector.
    private static let sheet: CGFloat = 760

    @State private var edited = "This retries for ever. Give it a ceiling.\n"
        + "Three attempts, then let the job fail so the queue can see it."
    @State private var written = "The webhook signature is computed over the raw body.\n"
        + "Serialising and re-encoding here changes it."

    private static func comment(_ body: String, line: Int = 179) -> ReviewComment {
        ReviewComment(
            workspaceID: WorkspaceID("w1"),
            filePath: "src/Jobs/CallWebhookJob.php",
            side: .new,
            anchor: ReviewCommentAnchor(
                line: line,
                text: "        $this->release($this->backoff());",
                before: ["    {", ""],
                after: ["    }", ""]
            ),
            body: body
        )
    }

    private static func placement(_ body: String, line: Int = 179) -> ReviewPlacement {
        ReviewPlacement(
            comment: comment(body, line: line),
            status: .placed(ReviewSpot(side: .new, line: line), moved: false)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("At rest") {
                ReviewCommentBandView(
                    placement: Self.placement("This retries for ever."),
                    width: Self.sheet,
                    onBeginEdit: {}, onCommitEdit: {}, onCancelEdit: {}, onRemove: {}
                )
            }

            group("Under the pointer") {
                ReviewCommentBandView(
                    placement: Self.placement("This retries for ever."),
                    width: Self.sheet,
                    isHovered: true,
                    onBeginEdit: {}, onCommitEdit: {}, onCancelEdit: {}, onRemove: {}
                )
            }

            group("Being rewritten, across two lines") {
                ReviewCommentBandView(
                    placement: Self.placement("This retries for ever."),
                    width: Self.sheet,
                    editing: $edited,
                    onBeginEdit: {}, onCommitEdit: {}, onCancelEdit: {}, onRemove: {}
                )
            }

            group("After the edit") {
                ReviewCommentBandView(
                    placement: Self.placement(edited),
                    width: Self.sheet,
                    onBeginEdit: {}, onCommitEdit: {}, onCancelEdit: {}, onRemove: {}
                )
            }

            group("A new comment, written across two lines") {
                ReviewCommentEditorView(
                    text: $written,
                    width: Self.sheet,
                    onCommit: {},
                    onCancel: {}
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Typo.micro)
                .foregroundStyle(Palette.textSecondary)
                .textCase(.uppercase)
            content()
        }
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// The one page whose subject is a caret: the review comment field draws its focus ring only in
    /// the key window of the active app.
    static let reviewComments = Gallery(
        name: "review-comments",
        title: "Review comments",
        size: CGSize(width: 820, height: 900),
        needsFocus: true,
        view: { _ in AnyView(ReviewCommentSnapshotGallery()) }
    )
}
