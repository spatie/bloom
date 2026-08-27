import SwiftUI

/// The welcome window's last screen: the prompt anybody can send back to the people who build
/// Bloom.
///
/// The owner asked for it. Bloom already has Help's Submit a Prompt, and a menu item is a feature
/// that only somebody already looking for it ever meets, which is word for word the argument the
/// command line step before this one is here on. A person who has just installed the app is the
/// one person who has an unspoilt list of things they wish it did.
///
/// **Every claim on it is the mechanism's, restated, and nothing on it is a promise the mechanism
/// does not keep.** `Feedback.Copy.promptBlurb` says a prompt we like gets run and merged, so this
/// says that and not that it gets read, answered or built. `Feedback.Copy.promptName` credits a
/// name in the changelog and `Feedback.Copy.promptEmail` writes to an address when the thing
/// ships, so those are the two reasons given for the two optional fields. What travels with it is
/// `Feedback.PromptSubmission`: the words, those two fields, and a fixed block of facts about this
/// machine that names no path, project, branch, workspace or session. See the head of `Feedback`,
/// which lists what is deliberately absent.
///
/// **It offers the action rather than describing it**, which is the difference between a screen
/// and a paragraph, and the button is the same sheet the menu item opens rather than a second form
/// written for this window. Pressing it leaves the welcome window: see `WelcomeView.submitAPrompt`
/// for why that is the only route to it rather than a courtesy, and why the caption says so out
/// loud instead of letting the window vanish unannounced.
struct WelcomePromptSubmission: View {
    /// Closes this window and raises the sheet, in that order. Held by `WelcomeView`, because
    /// finishing the sequence is that view's to do and this screen has no way to reach it.
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.pane - Metrics.spacingSmall) {
            // The same two rungs the checks and the command line screens open on, so all three
            // read as pages of one window: a serif line, then the sentence explaining it at the
            // rung this window sets prose at.
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                Text("Say what Bloom does next")
                    .font(Typo.displayHeading)
                    .foregroundStyle(Palette.textPrimary)

                Text(
                    "Prompt a coding agent to build what you want to see in Bloom, in the words "
                        + "you would say it to one. If we like your prompt we run it, and the "
                        + "result is merged."
                )
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: Metrics.spacing) {
                // Beside the button rather than above it, for the reason `CommandLineOffer` puts
                // its own note there: both facts are about what happens after the press, and this
                // is where the press is.
                HStack(alignment: .top, spacing: Metrics.gutter) {
                    Text(
                        "A name gets you credited in the changelog, an address gets you told when "
                            + "it ships, and both are optional. Nothing from your projects or "
                            + "your sessions goes with it."
                    )
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    // The ellipsis is doing work rather than decorating: this opens a form to
                    // type into, which is exactly what a Mac means by one, and it is the same
                    // ellipsis the menu item this reaches carries.
                    Button("Submit a prompt…") { onSubmit() }
                }

                // Where the window goes, and where the form lives afterwards, in the line the
                // command line screen uses to say the same two things about the settings pane. A
                // window that closed itself on a press with no warning would be the one moment in
                // this sequence that felt like a mistake.
                Text(
                    "The form opens in the main window, and the Help menu has it under Submit a "
                        + "Prompt whenever you want it."
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
