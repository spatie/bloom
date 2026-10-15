import SwiftUI

/// What an inline pane action left to say, either in the inspector or in Mail.
///
/// The pull request strip's notice lives on `WorkspaceModel`: the strip is a title bar accessory
/// and the notice is in the inspector, so the two views do not share SwiftUI state.
struct PaneNoticeContent: Identifiable, Equatable {
    let id = UUID()
    var tone: PaneNotice.Tone
    var title: String
    var message: String
    /// The command and its output, for someone who wants to see it. Nil when there is nothing
    /// behind the sentence.
    var details: String?
}

/// Something a pane has to say about what an action did, in the pane rather than a modal.
///
/// A merge that mostly worked must not stop the app. The alert it replaces was titled "Something
/// went wrong" and carried a shell command and a line of raw git output as its message, which is
/// three separate mistakes: it interrupted, it said the wrong thing (the merge had succeeded), and
/// it put a command line in front of someone who had pressed a button.
///
/// So the sentence is the message, and the command that produced it is behind a disclosure for the
/// one reader in twenty who wants it. The pull request details are a command line and git or gh
/// stderr. Mail notices carry no details.
struct PaneNotice: View {
    enum Tone {
        /// It worked, with something worth knowing.
        case info
        /// It did not work.
        case failure

        var color: Color {
            switch self {
            case .info: Palette.accent
            case .failure: Palette.negative
            }
        }

        var glyph: String {
            switch self {
            case .info: "info.circle.fill"
            case .failure: "exclamationmark.triangle.fill"
            }
        }
    }

    let notice: PaneNoticeContent
    let onDismiss: () -> Void

    @State private var isShowingDetails = false

    private var tone: Tone { notice.tone }
    private var title: String { notice.title }
    private var message: String { notice.message }
    private var details: String? { notice.details }

    var body: some View {
        HStack(alignment: .top, spacing: InspectorLayout.gap) {
            Image(systemName: tone.glyph)
                .font(Typo.caption)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: InspectorLayout.tight) {
                // Two lines at most, and truncated in the middle rather than at the tail.
                // The titles that can be any length are the ones that name a branch, and a
                // branch name a model wrote can be longer than this column will ever be: the
                // middle is what a reader can spare, since the prefix says whose it is and the
                // suffix says which attempt. The sentence under it names the branch again in
                // full and wraps freely, so nothing is only ever available truncated.
                Text(title)
                    .font(Typo.captionEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The expandable details below were already selectable and the sentence
                    // saying what failed was not, so the git output could be pasted and the
                    // explanation of it could not.
                    .textSelection(.enabled)

                if details != nil {
                    Button(isShowingDetails ? "Hide details" : "Show details") {
                        isShowingDetails.toggle()
                    }
                    .linkButton()
                    .font(Typo.micro)
                }

                if isShowingDetails, let details {
                    ScrollView(.horizontal) {
                        Text(details)
                            .font(Typo.codeTiny)
                            .foregroundStyle(Palette.textTertiary)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 96)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Palette.textTertiary)
                .help("Dismiss")
        }
        .padding(.horizontal, InspectorLayout.inset)
        .padding(.vertical, Metrics.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(InspectorLayout.tintOpacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(message)")
    }
}
