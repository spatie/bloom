import SwiftUI

/// Stop the turn that is running.
///
/// **It used to be the send button wearing a different glyph.** That was right for as long as the
/// two were never both available: you could not send while an agent was working, so one control
/// could mean "send" in one state and "stop" in the other with nothing to confuse. The composer
/// now queues a message typed mid turn instead of refusing it, so both actions are live at once,
/// and a single button would have to pick one of them. Either choice is a mis-press that does the
/// opposite of what the hand meant: killing a turn that was going fine, or queueing a sentence
/// when the point was to make the agent stop.
///
/// So Stop has its own control, and it appears immediately to the left of Send for exactly as long
/// as there is a turn to stop. That way Send never moves, which matters because Send is what
/// Return does and what the hand goes to without looking; and Stop is never somewhere new, because
/// it is either absent or in that one place. It is also still on the Workspace menu under Command
/// period, which is the route that works while the composer is not focused.
///
/// Quiet rather than prominent, which is the argument the shared button already made and it has
/// not changed: an escape hatch that sits there for the whole length of a ten minute turn must not
/// pull the eye like an alarm about work that is going fine. Bordered keeps it obviously a button
/// and the red says what it does without shouting it. The filled accent stays unique to the
/// primary action beside it, so the pair reads as one thing you are doing and one thing you may
/// do instead.
struct ComposerStopButton: View {
    var onStop: @MainActor () -> Void

    var body: some View {
        Button(action: onStop) {
            Label("Stop the agent", systemImage: "stop.fill")
                .labelStyle(.iconOnly)
                .font(Typo.labelEmphasis)
                .frame(width: ComposerSendButton.glyph, height: ComposerSendButton.glyph)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(Palette.stop)
        .help("Stop the agent (Command period)")
    }
}
