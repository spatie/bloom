import SwiftUI

/// The welcome window's third screen: the one command that lets the owner drive Bloom from a
/// terminal they already had open.
///
/// **It is an offer, and everything on it is arranged to read as one.** Bloom works perfectly
/// without the bridge, so there is no control here that has to be satisfied before anybody can
/// leave: the primary button in the footer says "Start using Bloom" and does exactly that whether
/// the command was copied or not, and the last line says where to find this again. A step that
/// felt required would be worse than the settings pane this came out of, because a settings pane
/// at least only wastes the time of somebody who went looking.
///
/// It is here rather than only in Settings because nobody browses a settings tab they do not know
/// exists. This is a capability that needs one command run once, and the moment to hold that
/// command out is while somebody is already being set up.
///
/// Everything that is also in the settings pane is drawn by `CommandLineOffer` and its two
/// neighbours, so the command, the instruction and the warning have one source between the two
/// screens. What this file adds is the framing: a headline, the ground the box sits on, and the
/// sentence that says it can be skipped.
struct WelcomeCommandLine: View {
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.pane - Metrics.spacingSmall) {
            // The same two rungs the checks screen opens on, so this reads as the next page of one
            // window rather than as a different window that happens to share a plinth.
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                Text("Use Bloom from your own terminal")
                    .font(.system(size: 19, weight: .medium, design: .serif))
                    .foregroundStyle(Palette.textPrimary)

                CommandLineInstruction(isLead: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: Metrics.spacing) {
                // Sunken, unlike the settings pane's, because this band is the raised colour
                // itself. See `CommandLineOffer.fill`.
                CommandLineOffer(command: command, fill: Palette.surfaceSunken)

                CommandLineWarning()

                // The whole of what makes this a step somebody may walk past, and it is one line
                // rather than a second button. A "Skip" next to a "Start using Bloom" would be two
                // ways out of a screen that only needs one, and the one it has already says what
                // pressing it does.
                Text(
                    "Bloom works without this. Settings has the command again, under Command Line, "
                        + "whenever you want it."
                )
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Metrics.pane)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
