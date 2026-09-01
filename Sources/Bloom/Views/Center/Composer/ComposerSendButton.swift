import SwiftUI

/// Send what is in the box, or create the workspace the sheet is about to cut.
///
/// **It used to be Send and Stop in one control**, on the argument that the two were never both
/// available and that a second button disabled most of the time is noise. The first half of that
/// stopped being true: a message typed while a turn is running now joins the chat's queue instead
/// of being refused, so both actions are live at once and neither may be the other's other state.
/// Stop moved out to `ComposerStopButton`, which appears to the left of this one while there is a
/// turn to stop. The argument survives its own conclusion: nothing here is ever disabled by
/// something being busy, only by there being nothing to send.
///
/// This one therefore does not move. It is the last control in the footer in every state, which is
/// what makes it the thing the hand goes to without looking, and it is what Return does.
///
/// In the create window it is the same button doing the same job for a conversation that does not
/// exist yet, so it says what it is about to do and shows the key that does it. See
/// `ComposerIntent`.
struct ComposerSendButton: View {
    var intent: ComposerIntent = .send
    /// Whether a turn is running, which changes nothing about whether this may be pressed and
    /// everything about what pressing it means. A message sent now goes into the queue in front of
    /// the agent rather than to the agent, and the tooltip is where that is said, because the
    /// bubble that appears afterwards is the honest version of the answer. See `DeliveryHold`.
    var isRunning: Bool = false
    var canSend: Bool
    var onSend: @MainActor () -> Void

    /// The bordered styles add four points of padding on every edge. A sixteen point glyph box
    /// produces a quiet twenty-four point circle, while the outer frame preserves the full footer
    /// row as the click target.
    ///
    /// Not private, because `ComposerStopButton` sits next to it and has to be the same circle.
    static let glyph = Metrics.rowHeight - Metrics.spacingSmall * 3

    /// A named action rather than a glyph, which only the create window uses. A round arrow is
    /// enough for a message going into a conversation the user is looking at; a control that is
    /// about to cut a branch and a worktree should say so, and the return glyph beside it says
    /// which key does it without a tooltip.
    private var isNamed: Bool { intent == .create }

    var body: some View {
        Button(action: onSend) {
            if isNamed {
                HStack(spacing: Metrics.spacingSmall) {
                    Text(intent.title)
                    Image(systemName: "return")
                        .imageScale(.small)
                }
                .font(Typo.labelEmphasis)
                .padding(.horizontal, Metrics.spacing)
                .frame(height: Self.glyph)
            } else {
                Label(intent.title, systemImage: "arrow.up")
                    .labelStyle(.iconOnly)
                    .font(Typo.labelEmphasis)
                    .frame(width: Self.glyph, height: Self.glyph)
            }
        }
        // Prominent, because sending is the action on offer and it is the only one here now.
        .buttonStyle(.borderedProminent)
        // **A rounded rectangle rather than a capsule, and the same radius every other named
        // button in the window takes.** The capsule was the only one of its kind in the app: the
        // Merge button, Create pull request and the rest all go through
        // `.roundedRectangle(radius: Metrics.corner)`, so a pill in the create window read as a
        // control borrowed from somewhere else. The round variant beside it stays a circle,
        // because a glyph in a circle is a different family and every footer already draws it.
        .buttonBorderShape(isNamed ? .roundedRectangle(radius: Metrics.corner) : .circle)
        .frame(minHeight: Metrics.rowHeight)
        .contentShape(Rectangle())
        // The system control accent keeps this primary action consistent with every native control.
        .tint(Palette.controlAccent)
        .disabled(!canSend)
        .help(isRunning ? "Queue this message. It goes when the turn ends (Return)" : intent.help)
    }
}
