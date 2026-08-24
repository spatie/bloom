import SwiftUI
import BloomCore

/// Every state of deleting a queued message on one page: the bubble at rest, under the pointer,
/// the question, and what the queue looks like once the answer is Delete.
///
/// It exists because the change is mostly about what a control looks like when nobody is pointing
/// at it. Delete used to be drawn at opacity zero until the pointer arrived, which is why the
/// owner asked for an ability the app already had, and judging the replacement means seeing the
/// resting and the pointed-at states next to each other in both appearances. No screen in the app
/// puts them there, and a diff shows neither.
///
/// **Photographed through `--snapshot-gallery` rather than `--snapshot`.** `ConfirmationSheet`
/// carries `AlertRole`, an `NSViewRepresentable`, and `ImageRenderer` paints one as a yellow
/// placeholder: rendered offscreen the confirmation came out as a yellow rectangle, which is
/// exactly the state worth reviewing. So this gets a real window and the window server is asked
/// for it.
struct PendingDeleteSnapshotGallery: View {
    /// The width the transcript caps a bubble at in a comfortable window.
    private static let bubble: CGFloat = 520

    private static func delivery(_ body: String) -> Delivery {
        Delivery(targetSessionID: SessionID("s1"), body: body)
    }

    /// The owner's own screenshot, which is what this was reported from.
    private static let typed = "sdfsd\nsdfsdf"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("At rest") {
                PendingTurnRowView(
                    delivery: Self.delivery(Self.typed),
                    hold: .question,
                    maxWidth: Self.bubble,
                    onDelete: {}
                )
            }

            group("Under the pointer") {
                PendingTurnRowView(
                    delivery: Self.delivery(Self.typed),
                    hold: .question,
                    maxWidth: Self.bubble,
                    onDelete: {},
                    pointerInside: true
                )
            }

            // Several can queue, and only the last carries the sentence. Deleting takes one of
            // them: the rest keep their places and their order, because the queue is a table and
            // the delete is one row leaving it.
            group("Three waiting, one sentence") {
                VStack(spacing: 0) {
                    PendingTurnRowView(
                        delivery: Self.delivery("Also check the migration."),
                        hold: nil,
                        maxWidth: Self.bubble,
                        onDelete: {}
                    )
                    PendingTurnRowView(
                        delivery: Self.delivery(Self.typed),
                        hold: nil,
                        maxWidth: Self.bubble,
                        onDelete: {},
                        pointerInside: true
                    )
                    PendingTurnRowView(
                        delivery: Self.delivery("And run the tests when you are done."),
                        hold: .turn,
                        maxWidth: Self.bubble,
                        onDelete: {}
                    )
                }
            }

            group("The question, when the composer is empty") {
                sheet(for: .toComposer(Self.typed))
            }

            group("The question, when the composer is not") {
                sheet(for: .discarded(.composerInUse))
            }

            group("After Delete, when the message had already gone") {
                NoticeBanner(
                    notice: BloomNotice(message: PendingMessageDiscard.alreadySentSentence),
                    onDismiss: {}
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sheet(for recovery: PendingMessageDiscard.Recovery) -> some View {
        let question = PendingMessageDiscard.question(for: recovery)
        return ConfirmationSheet(
            confirmation: Confirmation(
                title: question.title,
                message: question.message,
                confirmLabel: question.confirmLabel,
                cancelLabel: question.cancelLabel
            ),
            onConfirm: {},
            onCancel: {}
        )
        .fixedSize()
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
    static let pendingDelete = Gallery(
        name: "pending-delete",
        title: "Pending message delete",
        size: CGSize(width: 820, height: 900),
        needsFocus: false,
        view: { _ in AnyView(PendingDeleteSnapshotGallery()) }
    )
}
