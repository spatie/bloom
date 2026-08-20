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

/// How long the thanks stays on screen before the sheet closes itself.
///
/// Long enough to be read, short enough not to be a step. The same pause `GitHubSignInSheet` uses
/// after a successful sign in, for the same reason: the confirmation is worth seeing and is not
/// worth a button.
let feedbackSuccessPause = Duration.milliseconds(900)

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

/// What happened to the send, said where the buttons are.
///
/// A failure is a sentence rather than an alert. An alert would take the sheet's own text out from
/// under the person reading it, and the one thing that must never be in doubt here is that their
/// words are still where they left them.
struct FeedbackStatus: View {
    var phase: FeedbackPhase
    var sentMessage: String

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .sending:
            HStack(spacing: Metrics.spacingWide) {
                ProgressView().controlSize(.small)
                Text("Sending")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
            }
        case .sent:
            Label(sentMessage, systemImage: "checkmark.circle.fill")
                .font(Typo.label)
                .foregroundStyle(Palette.positive)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Typo.label)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The primary button, with the key that presses it written on it.
///
/// The shortcut is drawn rather than left to be discovered, because Return in a box that takes
/// paragraphs has to mean a new line, which makes Command+Return the only way to send and
/// therefore something the sheet has to say out loud.
struct FeedbackSendButton: View {
    var title: String
    var isEnabled: Bool
    var action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.spacingSmall) {
                Text(title)
                Text(verbatim: "⌘↩").opacity(0.65)
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
