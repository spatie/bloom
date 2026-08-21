import SwiftUI

/// The floating "you are not at the end" affordance, drawn inside the transcript above its bottom
/// edge. `ChatPaneView` places it and says why it is not on the composer any more.
///
/// It answers one question, and only one: the transcript has moved on below where you are reading,
/// take me back to it. So it appears when the view is away from the live end and at no other time,
/// and it goes as soon as the end is reached again.
///
/// It used to say "Next unread (64)" and it used to be shown whenever the session held anything
/// unread, which is a different claim and was not one the window could support. Unread is what the
/// sidebar bolds, what the Dock badge counts and what the menu bar item sums, and all three are
/// about workspaces you are NOT looking at. Inside the conversation you are looking at, everything
/// on screen has been seen by definition, and a count in the sixties for rows that had scrolled
/// past under the pointer read as a backlog rather than as a hint. The number is gone with it:
/// how far behind you are does not change what the button does or whether you want it.
struct JumpToNewestPill: View {
    var action: @MainActor () -> Void

    var body: some View {
        // A real prominent button rather than a hand-painted capsule: it then gets the pressed
        // and disabled states, the hover response and the accent tint from the system instead of
        // from an opacity that only changed on hover.
        Button(action: action) {
            Label("Jump to newest", systemImage: "arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        // `accentFill` for the reason spelled out on `ComposerSendButton`: this is a filled
        // control with a white label on it.
        .tint(Palette.accentFill)
        // The transcript's own ground, behind the button, so the pill is opaque whatever the
        // button style decides to fill itself with.
        //
        // It floats over the conversation now rather than over the composer's surface, and a
        // `borderedProminent` button in a window that is not the active one is drawn with no fill
        // at all: a black label and a hairline of grey. Over a prompt box that reads as a quiet
        // button, over a paragraph it reads as a smear, because the row's own words run straight
        // through the label. Captured on an inactive window and unreadable at a glance.
        .background(Capsule().fill(Palette.surface))
        // Black rather than the label colour, which would be a white glow in dark mode.
        .shadow(color: .black.opacity(0.2), radius: Metrics.spacingSmall, y: Metrics.spacingTight)
        .help("Jump to the newest row")
    }
}
