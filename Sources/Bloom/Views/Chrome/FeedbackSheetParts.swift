import SwiftUI
import BloomCore

/// Where a submission has got to. Shared by both Help menu sheets, because both of them do exactly
/// one thing: take what was typed, put it on the wire, and say what happened.
enum FeedbackPhase: Equatable {
    case idle
    case sending
    /// The server took it. The sheet says so and then gets out of the way.
    case sent
    case failed(String)

    var isSending: Bool { self == .sending }
}


/// The heading and the sentence under it, which is the same shape on both sheets.
struct FeedbackHeader: View {
    var title: String
    var blurb: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text(title)
                .font(Typo.heading)
                .foregroundStyle(Palette.textPrimary)

            Text(blurb)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What went wrong with the send, said where the buttons are.
///
/// A failure is a sentence rather than an alert. An alert would take the sheet's own text out from
/// under the person reading it, and the one thing that must never be in doubt here is that their
/// words are still where they left them.
///
/// It says nothing at all about sending or having sent. Sending is on the button, which is the
/// control that was pressed and so the place somebody is already looking; having sent replaces the
/// whole form with `FeedbackSentCard`. Both used to be drawn here, which meant a spinner appeared
/// beside a button that still looked pressable.
struct FeedbackStatus: View {
    var phase: FeedbackPhase

    var body: some View {
        if case .failed(let message) = phase {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Typo.label)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The optional address, which both sheets ask for and neither requires.
///
/// One view rather than two, because the field, its rule and the sentence under a bad address are
/// the same on both; only the label differs, and it differs because what will be done with the
/// address differs.
struct FeedbackEmailField: View {
    var label: String
    @Binding var email: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text(label)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(Feedback.Copy.emailPlaceholder, text: $email)
                .textFieldStyle(.roundedBorder)
                .font(Typo.body)

            // Checked here rather than only on the way out, because the alternative is a
            // submission that comes back 422 for a field nobody had to fill in at all.
            if !Feedback.isAcceptableEmail(email) {
                Label(Feedback.emailProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What replaces the form once the words have arrived.
///
/// A card in the sheet that was already open rather than a second sheet raised behind a first one
/// being dismissed. Dismissing and presenting in the same turn is the SwiftUI arrangement that
/// drops the second sheet on the floor often enough to be a bug report; swapping the item on one
/// `.sheet(item:)` binding is a content change, which is reliable and reads better anyway: the
/// form somebody was looking at becomes the answer to it.
struct FeedbackSentCard: View {
    var title: String
    var detail: String
    var onDismiss: @MainActor () -> Void

    private static let width: CGFloat = 380

    var body: some View {
        VStack(spacing: Metrics.gutter) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.positive)

            VStack(spacing: Metrics.spacingWide) {
                Text(title)
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)

                Text(detail)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(Feedback.Copy.sentDismiss, action: onDismiss)
                .buttonStyle(.borderedProminent)
                .tint(Palette.accentFill)
                // Both keys, because this card has one button and either key should press it:
                // Return is what a dialog with one button trains you to press, and Escape is what
                // anybody who has already read it will reach for.
                .keyboardShortcut(.defaultAction)
        }
        .padding(Metrics.pane)
        .frame(width: Self.width)
        .background(Palette.surface)
        // Escape, which a `.cancelAction` button would carry and there is no cancel button here.
        .onExitCommand(perform: onDismiss)
    }
}

/// The primary button, with the key that presses it written on it.
///
/// The shortcut is drawn rather than left to be discovered, because Return in a box that takes
/// paragraphs has to mean a new line, which makes Command+Return the only way to send and
/// therefore something the sheet has to say out loud.
///
/// While a send is in flight the shortcut hint is replaced by a spinner in the same place, so the
/// button reports its own progress rather than a line of text somewhere else doing it. The title
/// stays put and the width barely moves, because a button that resizes under the cursor at the
/// moment it is pressed is the one thing worse than no feedback at all.
struct FeedbackSendButton: View {
    var title: String
    var isEnabled: Bool
    var isSending: Bool
    var action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.spacingSmall) {
                Text(title)

                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        // The width the shortcut hint occupies, so swapping one for the other
                        // does not move the title under the cursor.
                        .frame(width: 20)
                } else {
                    Text(verbatim: "⌘↩").opacity(0.65)
                }
            }
        }
        .buttonStyle(.borderedProminent)
        // Tinted explicitly, like every other prominent button in the app: untinted it follows the
        // system accent and renders as grey glass on macOS 26.
        .tint(Palette.accentFill)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!isEnabled)
    }
}

/// The line under both send buttons, naming what travels besides what was typed.
struct FeedbackEnvironmentNote: View {
    var body: some View {
        Text(Feedback.Copy.environmentNote)
            .font(Typo.micro)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
